import XCTest
import Combine
@testable import MimiRemote

@MainActor
final class ConversationDataFlowTests: XCTestCase {
    func testThemeStorePersistsThemePresetFontsAndFontScale() throws {
        let suiteName = "ThemeStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ThemeStore(defaults: defaults)
        XCTAssertEqual(store.mode, .system)
        XCTAssertEqual(store.preset, .codex)
        XCTAssertEqual(store.uiFontPreset, .system)
        XCTAssertEqual(store.codeFontPreset, .systemMono)
        XCTAssertEqual(store.fontScale, 1.0, accuracy: 0.001)

        let initialVersion = store.themeVersion
        store.mode = .dark
        store.preset = .gruvbox
        store.uiFontPreset = .rounded
        store.codeFontPreset = .menlo
        store.setFontScale(1.2)

        XCTAssertEqual(store.mode, .dark)
        XCTAssertEqual(store.preset, .gruvbox)
        XCTAssertEqual(store.uiFontPreset, .rounded)
        XCTAssertEqual(store.codeFontPreset, .menlo)
        XCTAssertEqual(store.fontScale, 1.2, accuracy: 0.001)
        XCTAssertGreaterThan(store.themeVersion, initialVersion)

        let reloaded = ThemeStore(defaults: defaults)
        XCTAssertEqual(reloaded.mode, .dark)
        XCTAssertEqual(reloaded.preset, .gruvbox)
        XCTAssertEqual(reloaded.uiFontPreset, .rounded)
        XCTAssertEqual(reloaded.codeFontPreset, .menlo)
        XCTAssertEqual(reloaded.fontScale, 1.2, accuracy: 0.001)
        XCTAssertEqual(reloaded.themeVersion, store.themeVersion)
    }

    func testThemeStoreClampsFontScaleAndScalesSizes() throws {
        let suiteName = "ThemeStoreScaleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ThemeStore(defaults: defaults)

        store.setFontScale(9.0)
        XCTAssertEqual(store.fontScale, ThemeStore.maximumFontScale, accuracy: 0.001)
        XCTAssertEqual(store.scaledFontSize(16), 16 * CGFloat(ThemeStore.maximumFontScale), accuracy: 0.001)

        store.setFontScale(0.1)
        XCTAssertEqual(store.fontScale, ThemeStore.minimumFontScale, accuracy: 0.001)
        XCTAssertEqual(store.scaledFontSize(20), 20 * CGFloat(ThemeStore.minimumFontScale), accuracy: 0.001)
    }

    func testConversationMessageRenderFingerprintTracksContentRevision() {
        var message = ConversationMessage(
            role: .assistant,
            content: String(repeating: "长消息", count: 4_000),
            sendStatus: .sending
        )
        let initial = message.renderFingerprint

        message.sendStatus = .confirmed
        XCTAssertEqual(message.renderFingerprint, initial)
        XCTAssertEqual(message.contentRevision, 0)

        message.content += "尾部增量"
        XCTAssertNotEqual(message.renderFingerprint, initial)
        XCTAssertEqual(message.contentRevision, 1)
        XCTAssertGreaterThan(message.contentByteCount, initial.contentByteCount)
    }

    func testConversationTimelineForcesTailFollowOnlyForLocalUserSubmissions() {
        let localSubmission = ConversationMessage(
            clientMessageID: "client-tail",
            role: .user,
            content: "继续修复滚动",
            sendStatus: .sending
        )
        XCTAssertTrue(ConversationTimelineView.shouldForceTailFollow(forNewTailMessage: localSubmission))

        let replayedHistoryUser = ConversationMessage(
            role: .user,
            content: "历史里的旧问题",
            sendStatus: .confirmed
        )
        XCTAssertFalse(ConversationTimelineView.shouldForceTailFollow(forNewTailMessage: replayedHistoryUser))

        let assistantReply = ConversationMessage(
            clientMessageID: "client-ignored",
            role: .assistant,
            content: "收到",
            sendStatus: .sending
        )
        XCTAssertFalse(ConversationTimelineView.shouldForceTailFollow(forNewTailMessage: assistantReply))

        let processSummary = ConversationMessage(
            clientMessageID: "client-process",
            role: .user,
            kind: .commandSummary,
            content: "命令：go test ./...",
            sendStatus: .sent
        )
        XCTAssertFalse(ConversationTimelineView.shouldForceTailFollow(forNewTailMessage: processSummary))
    }

    func testConversationTimelineAllowsInitialTailRetryButRespectsUserScrollAway() {
        XCTAssertTrue(ConversationTimelineView.shouldAttemptTailScroll(
            force: false,
            shouldFollowMessageTail: false,
            forceNextMessageTailScroll: true,
            isTailFollowLockedByLocalSubmit: false,
            isTimelineNearBottom: false
        ))

        XCTAssertTrue(ConversationTimelineView.shouldAttemptTailScroll(
            force: false,
            shouldFollowMessageTail: false,
            forceNextMessageTailScroll: false,
            isTailFollowLockedByLocalSubmit: false,
            isTimelineNearBottom: true
        ))

        XCTAssertFalse(ConversationTimelineView.shouldAttemptTailScroll(
            force: false,
            shouldFollowMessageTail: false,
            forceNextMessageTailScroll: false,
            isTailFollowLockedByLocalSubmit: false,
            isTimelineNearBottom: false
        ))

        XCTAssertTrue(ConversationTimelineView.shouldAttemptTailScroll(
            force: true,
            shouldFollowMessageTail: false,
            forceNextMessageTailScroll: false,
            isTailFollowLockedByLocalSubmit: false,
            isTimelineNearBottom: false
        ))
    }

    func testTimestampCaptionMarksFallbackTimes() {
        let fallback = ConversationMessage(
            role: .assistant,
            content: "历史时间缺失",
            createdAt: Date(timeIntervalSince1970: 100),
            sendStatus: .confirmed,
            isTimestampFallback: true
        )
        let normal = ConversationMessage(
            role: .assistant,
            content: "历史时间可信",
            createdAt: Date(timeIntervalSince1970: 100),
            sendStatus: .confirmed
        )

        XCTAssertEqual(fallback.timestampCaptionText, normal.timestampCaptionText)
        XCTAssertTrue(fallback.isTimestampFallback)
        XCTAssertFalse(normal.isTimestampFallback)
    }

    func testStreamingAssistantDeltaRefreshesLatestTimestamp() throws {
        let store = ConversationStore()
        let sessionID = "sess_stream_timestamp"
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let latestAt = Date(timeIntervalSince1970: 1_090)
        let baseMetadata = AgentEventMetadata(
            seq: 1,
            sessionID: sessionID,
            turnID: "turn_stream_timestamp",
            itemID: "item_stream_timestamp",
            messageID: "message_stream_timestamp",
            clientMessageID: nil,
            revision: 1,
            createdAt: startedAt
        )
        store.applyAssistantDelta(
            AgentDelta(text: "第一段", role: .assistant, kind: .message),
            metadata: baseMetadata,
            fallbackSessionID: sessionID
        )
        store.applyAssistantDelta(
            AgentDelta(text: "第二段", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 2,
                sessionID: sessionID,
                turnID: "turn_stream_timestamp",
                itemID: "item_stream_timestamp",
                messageID: "message_stream_timestamp",
                clientMessageID: nil,
                revision: 2,
                createdAt: latestAt
            ),
            fallbackSessionID: sessionID
        )
        store.appendSystem("flush pending delta", sessionID: sessionID)

        let assistant = try XCTUnwrap(store.messages(for: sessionID).first { $0.role == .assistant })
        XCTAssertEqual(assistant.content, "第一段第二段")
        XCTAssertEqual(assistant.createdAt, startedAt)
        XCTAssertEqual(assistant.updatedAt, latestAt)
        XCTAssertTrue(assistant.timestampCaptionText.contains("最近"))
    }

    func testHistoryHydrationKeepsLiveActivityPayloadWhenSnapshotLacksPayload() throws {
        let store = ConversationStore()
        let sessionID = "sess_activity_payload_merge"
        let turnID = "turn_activity_payload_merge"
        let itemID = "cmd_activity_payload_merge"
        let item: [String: CodexAppServerJSONValue] = [
            "type": .string("commandExecution"),
            "id": .string(itemID),
            "command": .string("go test ./..."),
            "cwd": .string("/tmp/activity"),
            "status": .string("completed"),
            "commandActions": .array([.object(["name": .string("search"), "query": .string("ConversationStore")])]),
            "aggregatedOutput": .string("ok"),
            "exitCode": .int(0)
        ]
        let payload = try XCTUnwrap(ConversationActivityPayload(item: item))
        let stableID = "appserver:\(turnID):\(itemID)"
        let createdAt = Date(timeIntervalSince1970: 100)
        store.completeMessage(
            AgentMessage(
                id: stableID,
                sessionID: sessionID,
                turnID: turnID,
                itemID: itemID,
                role: .system,
                kind: .commandSummary,
                content: payload.summaryText,
                activityPayload: payload,
                createdAt: createdAt,
                revision: 1
            ),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: turnID,
                itemID: itemID,
                messageID: stableID,
                clientMessageID: nil,
                revision: 1,
                createdAt: createdAt
            ),
            fallbackSessionID: sessionID
        )

        store.setHistory([
            CodexHistoryMessage(
                id: stableID,
                role: "system",
                kind: .commandSummary,
                content: payload.summaryText,
                createdAt: createdAt,
                turnID: turnID,
                itemID: itemID,
                timelineOrdinal: 1
            )
        ], sessionID: sessionID)

        let message = try XCTUnwrap(store.messages(for: sessionID).first)
        XCTAssertEqual(message.activityPayload, payload)
        XCTAssertEqual(message.activityPayload?.displayTitle, "搜索 ConversationStore")
        XCTAssertEqual(message.content, payload.summaryText)
    }

    func testSessionDisplayStatusUsesForegroundAndGoalProgress() {
        let goal = ThreadGoal(
            threadID: "session-1",
            objective: "完成 iPad 对话体验优化",
            status: .active,
            tokenBudget: 1_000,
            tokensUsed: 250,
            timeUsedSeconds: 75
        )
        let session = AgentSession(
            id: "session-1",
            projectID: "project-1",
            project: "Mimi",
            dir: "/tmp/mimi",
            title: "修复会话体验",
            status: SessionStatus.running.rawValue,
            source: "codex",
            resumeID: nil,
            createdAt: nil,
            updatedAt: nil,
            activeTurnID: "turn-1",
            goal: goal
        )

        XCTAssertEqual(session.displayStatus(foregroundActivity: .receivingAssistant).title, "正在回复")
        XCTAssertEqual(goal.budgetPercentText, "25%")
        XCTAssertEqual(try XCTUnwrap(goal.budgetProgressFraction), 0.25, accuracy: 0.001)
        XCTAssertTrue(session.statusBadges(foregroundActivity: .receivingAssistant).contains { badge in
            badge.title == "目标 运行中 25%"
        })

        let approvalSession = AgentSession(
            id: "session-2",
            projectID: "project-1",
            project: "Mimi",
            dir: "/tmp/mimi",
            title: "审批会话",
            status: SessionStatus.waitingForApproval.rawValue,
            source: "codex",
            resumeID: nil,
            createdAt: nil,
            updatedAt: nil,
            pendingApproval: ApprovalSummary(id: "approval-1", title: "写入文件", kind: "command", count: 1)
        )

        XCTAssertEqual(approvalSession.displayStatus(foregroundActivity: .receivingAssistant).title, "待审批")
    }

    func testConversationFileReferenceDetectorFindsPreviewableAbsolutePaths() {
        let text = """
        已生成：
        - `/tmp/report.pdf`
        - file:///tmp/chart.png?download=1
        - /tmp/report.pdf
        - /tmp/source.swift:12
        - https://example.com/file.pdf
        - /tmp/output
        """

        let references = ConversationFileReferenceDetector.references(in: text)

        XCTAssertEqual(references.map(\.path), ["/tmp/report.pdf", "/tmp/chart.png"])
        XCTAssertEqual(references.map(\.name), ["report.pdf", "chart.png"])
    }

    func testConversationImageSourceRecognizesHistoryMediaPlaceholder() {
        let source = ConversationImageSource.markdown("agentd-history-media://media_abc")

        XCTAssertEqual(source, .historyMedia(id: "media_abc"))
    }

    func testConversationMessageEqualityAndHashIncludeTurnPayload() {
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 42)
        let firstPayload = CodexAppServerTurnPayload(input: [
            .text("看图"),
            .image(url: "data:image/png;base64,AA==", detail: .high)
        ])
        let secondPayload = CodexAppServerTurnPayload(input: [
            .text("看图"),
            .image(url: "data:image/png;base64,BBBB", detail: .high)
        ])
        let first = ConversationMessage(
            id: id,
            stableID: "message-1",
            clientMessageID: "client-1",
            turnID: "turn-1",
            itemID: "item-1",
            role: .user,
            content: "看图 [图片]",
            createdAt: createdAt,
            sendStatus: .sent,
            revision: 1,
            turnPayload: firstPayload
        )
        let second = ConversationMessage(
            id: id,
            stableID: "message-1",
            clientMessageID: "client-1",
            turnID: "turn-1",
            itemID: "item-1",
            role: .user,
            content: "看图 [图片]",
            createdAt: createdAt,
            sendStatus: .sent,
            revision: 1,
            turnPayload: secondPayload
        )

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 2)
    }

    func testTimelineBuilderCollapsesProcessMessagesBeforeCompletedAssistant() throws {
        let base = Date(timeIntervalSince1970: 1_000)
        let user = ConversationMessage(
            stableID: "user-1",
            role: .user,
            content: "检查 UI 展示",
            createdAt: base,
            sendStatus: .confirmed
        )
        let command = ConversationMessage(
            stableID: "cmd-1",
            turnID: "turn-processed",
            role: .system,
            kind: .commandSummary,
            content: "命令：xcodebuild test",
            createdAt: base.addingTimeInterval(1),
            sendStatus: .confirmed
        )
        let diff = ConversationMessage(
            stableID: "diff-1",
            turnID: "turn-processed",
            role: .system,
            kind: .fileChangeSummary,
            content: "文件变更：ConversationView.swift modified",
            createdAt: base.addingTimeInterval(4),
            sendStatus: .confirmed
        )
        let assistant = ConversationMessage(
            stableID: "assistant-1",
            turnID: "turn-processed",
            role: .assistant,
            content: "已完成，最终回答保持展开。",
            createdAt: base.addingTimeInterval(10),
            sendStatus: .confirmed
        )

        let items = ConversationTimelineItemBuilder.items(from: [user, command, diff, assistant])

        XCTAssertEqual(items.count, 3)
        if case .message(let first) = items[0] {
            XCTAssertEqual(first.content, "检查 UI 展示")
        } else {
            XCTFail("用户消息不应被折叠")
        }
        let group: ProcessedConversationGroup
        if case .processed(let processed) = items[1] {
            group = processed
        } else {
            return XCTFail("过程消息应聚合成已处理折叠组")
        }
        XCTAssertEqual(group.messages.map(\.content), ["命令：xcodebuild test", "文件变更：ConversationView.swift modified"])
        XCTAssertEqual(group.title, "已处理 2 步 · 9s")
        if case .message(let final) = items[2] {
            XCTAssertEqual(final.role, .assistant)
            XCTAssertEqual(final.content, "已完成，最终回答保持展开。")
        } else {
            XCTFail("最终 assistant 消息必须保持独立展开")
        }
    }

    func testTimelineBuilderDoesNotCollapseProcessMessagesIntoDifferentTurn() {
        let base = Date(timeIntervalSince1970: 1_500)
        let command = ConversationMessage(
            stableID: "cmd-other-turn",
            turnID: "turn-a",
            role: .system,
            kind: .commandSummary,
            content: "命令：go test ./...",
            createdAt: base,
            sendStatus: .confirmed
        )
        let assistant = ConversationMessage(
            stableID: "assistant-other-turn",
            turnID: "turn-b",
            role: .assistant,
            content: "这是另一个 turn 的最终回复。",
            createdAt: base.addingTimeInterval(5),
            sendStatus: .confirmed
        )

        let items = ConversationTimelineItemBuilder.items(from: [command, assistant])

        XCTAssertEqual(items.count, 2)
        if case .message(let first) = items[0] {
            XCTAssertEqual(first.turnID, "turn-a")
        } else {
            XCTFail("不同 turn 的过程消息不能折叠到后续 assistant")
        }
    }

    func testTimelineBuilderPlacesLateProcessMessagesBeforeTheirCompletedAssistant() throws {
        let base = Date(timeIntervalSince1970: 1_700)
        let user = ConversationMessage(
            stableID: "user-late-process",
            role: .user,
            content: "先出最终回复再出 diff",
            createdAt: base,
            sendStatus: .confirmed
        )
        let assistant = ConversationMessage(
            stableID: "assistant-late-process",
            turnID: "turn-late-process",
            role: .assistant,
            content: "最终回答仍然完整展示。",
            createdAt: base.addingTimeInterval(5),
            sendStatus: .confirmed
        )
        let diff = ConversationMessage(
            stableID: "diff-late-process",
            turnID: "turn-late-process",
            role: .system,
            kind: .fileChangeSummary,
            content: "文件变更：README.md modified",
            createdAt: base.addingTimeInterval(9),
            sendStatus: .confirmed
        )

        let items = ConversationTimelineItemBuilder.items(from: [user, assistant, diff])

        XCTAssertEqual(items.count, 3)
        if case .message(let first) = items[0] {
            XCTAssertEqual(first.role, .user)
        } else {
            XCTFail("用户消息应保持在首位")
        }
        let group: ProcessedConversationGroup
        if case .processed(let processed) = items[1] {
            group = processed
        } else {
            return XCTFail("迟到的过程消息应按 turnID 归到最终回复之前")
        }
        XCTAssertEqual(group.messages.map(\.content), ["文件变更：README.md modified"])
        XCTAssertEqual(group.title, "已处理 1 步 · 4s")
        if case .message(let final) = items[2] {
            XCTAssertEqual(final.content, "最终回答仍然完整展示。")
        } else {
            XCTFail("最终 assistant 消息仍应独立展示")
        }
    }

    func testTimelineBuilderKeepsProcessMessagesVisibleWhileAssistantIsStreaming() {
        let base = Date(timeIntervalSince1970: 2_000)
        let command = ConversationMessage(
            stableID: "cmd-streaming",
            turnID: "turn-streaming",
            role: .system,
            kind: .commandSummary,
            content: "命令仍在运行",
            createdAt: base,
            sendStatus: .confirmed
        )
        let assistant = ConversationMessage(
            stableID: "assistant-streaming",
            turnID: "turn-streaming",
            role: .assistant,
            content: "正在输出",
            createdAt: base.addingTimeInterval(2),
            sendStatus: .sending
        )

        let items = ConversationTimelineItemBuilder.items(from: [command, assistant])

        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items.contains { item in
            if case .processed = item {
                return true
            }
            return false
        })
    }

    func testTimelineBuilderKeepsAllProcessMessagesVisibleDuringActiveTurn() {
        let base = Date(timeIntervalSince1970: 2_200)
        let command = ConversationMessage(
            stableID: "cmd-active-interactive",
            turnID: "turn-active-interactive",
            role: .system,
            kind: .commandSummary,
            content: "命令仍在运行",
            createdAt: base,
            sendStatus: .confirmed
        )
        let approval = ConversationMessage(
            stableID: "approval-active-interactive",
            turnID: "turn-active-interactive",
            role: .system,
            kind: .approval,
            content: "需要批准运行命令",
            createdAt: base.addingTimeInterval(1),
            sendStatus: .confirmed
        )
        let assistant = ConversationMessage(
            stableID: "assistant-active-interactive",
            turnID: "turn-active-interactive",
            role: .assistant,
            content: "等待确认",
            createdAt: base.addingTimeInterval(2),
            sendStatus: .sending
        )

        let items = ConversationTimelineItemBuilder.items(from: [command, approval, assistant])

        // 运行中不折叠：命令、审批、streaming assistant 全部平铺，保持实时可见可操作。
        XCTAssertEqual(items.count, 3)
        guard case .message(let visibleCommand) = items[0] else {
            return XCTFail("运行中的命令卡必须保持完整可见")
        }
        XCTAssertEqual(visibleCommand.kind, .commandSummary)
        guard case .message(let visibleApproval) = items[1] else {
            return XCTFail("运行中的审批必须保持可见可操作")
        }
        XCTAssertEqual(visibleApproval.kind, .approval)
        guard case .message(let streamingAssistant) = items[2] else {
            return XCTFail("assistant streaming 内容仍应保留")
        }
        XCTAssertEqual(streamingAssistant.sendStatus, .sending)
    }

    func testTimelineBuilderKeepsProcessMessagesVisibleWhenAssistantFailed() {
        let base = Date(timeIntervalSince1970: 2_500)
        let command = ConversationMessage(
            stableID: "cmd-failed",
            turnID: "turn-failed",
            role: .system,
            kind: .commandSummary,
            content: "命令执行失败",
            createdAt: base,
            sendStatus: .confirmed
        )
        let assistant = ConversationMessage(
            stableID: "assistant-failed",
            turnID: "turn-failed",
            role: .assistant,
            content: "无法完成。",
            createdAt: base.addingTimeInterval(2),
            sendStatus: .failed
        )

        let items = ConversationTimelineItemBuilder.items(from: [command, assistant])

        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items.contains { item in
            if case .processed = item {
                return true
            }
            return false
        })
    }

    func testTimelineBuilderDoesNotHideErrorMessagesInsideProcessedGroup() {
        let base = Date(timeIntervalSince1970: 3_000)
        let error = ConversationMessage(
            stableID: "error-1",
            role: .system,
            kind: .error,
            content: "运行错误：网络断开",
            createdAt: base,
            sendStatus: .confirmed
        )
        let assistant = ConversationMessage(
            stableID: "assistant-after-error",
            role: .assistant,
            content: "失败原因如上。",
            createdAt: base.addingTimeInterval(3),
            sendStatus: .confirmed
        )

        let items = ConversationTimelineItemBuilder.items(from: [error, assistant])

        XCTAssertEqual(items.count, 2)
        if case .message(let first) = items[0] {
            XCTAssertEqual(first.kind, .error)
        } else {
            XCTFail("错误消息必须直接可见")
        }
    }

    func testAppendSystemPreservesRuntimeTurnMetadata() throws {
        let store = ConversationStore()
        let sessionID = "sess-runtime-metadata"
        let metadata = AgentEventMetadata(
            seq: 9,
            sessionID: sessionID,
            turnID: "turn-runtime",
            itemID: "item-diff",
            messageID: "message-diff",
            clientMessageID: nil,
            revision: 3,
            createdAt: Date(timeIntervalSince1970: 4_000)
        )

        store.appendSystem(
            "文件变更：ConversationView.swift modified",
            sessionID: sessionID,
            kind: .fileChangeSummary,
            metadata: metadata
        )

        let message = try XCTUnwrap(store.messages(for: sessionID).first)
        XCTAssertEqual(message.turnID, "turn-runtime")
        XCTAssertEqual(message.itemID, "item-diff")
        XCTAssertEqual(message.revision, 3)
        XCTAssertEqual(message.createdAt, Date(timeIntervalSince1970: 4_000))
        XCTAssertNil(message.clientMessageID)
    }

    func testSystemRuntimeMetadataDoesNotStealUserClientMessageIndex() throws {
        let store = ConversationStore()
        let sessionID = "sess-client-index"
        let clientMessageID = "client-shared"
        store.appendLocalUser("运行测试", sessionID: sessionID, clientMessageID: clientMessageID, sendStatus: .sending)
        store.appendSystem(
            "文件变更：README.md modified",
            sessionID: sessionID,
            kind: .fileChangeSummary,
            metadata: AgentEventMetadata(
                seq: 11,
                sessionID: sessionID,
                turnID: "turn-client-index",
                itemID: "diff-client-index",
                messageID: nil,
                clientMessageID: clientMessageID,
                revision: 1,
                createdAt: nil
            )
        )

        store.updateSendStatus(clientMessageID: clientMessageID, sessionID: sessionID, status: .confirmed)

        let messages = store.messages(for: sessionID)
        let user = try XCTUnwrap(messages.first)
        let system = try XCTUnwrap(messages.last)
        XCTAssertEqual(user.role, .user)
        XCTAssertEqual(user.sendStatus, .confirmed)
        XCTAssertEqual(system.role, .system)
        XCTAssertNil(system.clientMessageID)
    }

    func testCompletedRuntimeMessageDoesNotStealUserClientMessageIndex() throws {
        let store = ConversationStore()
        let sessionID = "sess-completed-client-index"
        let clientMessageID = "client-completed-shared"
        store.appendLocalUser("运行命令", sessionID: sessionID, clientMessageID: clientMessageID, sendStatus: .sending)
        store.completeMessage(
            AgentMessage(
                id: "tool-completed",
                sessionID: sessionID,
                clientMessageID: clientMessageID,
                turnID: "turn-completed-client-index",
                itemID: "tool-item",
                role: .tool,
                kind: .message,
                content: "go test ./...",
                // 时间戳保持不早于上面的本地回显：本测试只关注 client index 不被抢占，
                // 更早时间戳的 completed 消息如今会按时间线插回前面（有专门的排序测试覆盖）。
                createdAt: Date(),
                revision: 1,
                sendStatus: .confirmed
            ),
            metadata: .empty,
            fallbackSessionID: sessionID
        )

        store.updateSendStatus(clientMessageID: clientMessageID, sessionID: sessionID, status: .confirmed)

        let messages = store.messages(for: sessionID)
        let user = try XCTUnwrap(messages.first)
        let runtime = try XCTUnwrap(messages.last)
        XCTAssertEqual(user.role, .user)
        XCTAssertEqual(user.sendStatus, .confirmed)
        XCTAssertEqual(runtime.role, .system)
        XCTAssertEqual(runtime.kind, .commandSummary)
        XCTAssertNil(runtime.clientMessageID)
    }

    func testMessageRenderPlanCacheReusesAppendOnlyStreamingPrefix() {
        let cache = MessageRenderPlanCache(limit: 4)
        var message = ConversationMessage(
            stableID: "assistant:render",
            role: .assistant,
            content: "先解释一下\n```swift\nlet a = 1\n",
            sendStatus: .sending
        )

        let first = cache.plan(for: message)
        XCTAssertTrue(first.blocks.contains { block in
            if case let .codeBlock(language, code) = block.kind {
                return language == "swift" && code.contains("let a = 1")
            }
            return false
        })
        XCTAssertEqual(first.openTailByteOffset, "先解释一下\n".utf8.count)

        message.content += "let b = 2\n```"
        let second = cache.plan(for: message)

        XCTAssertEqual(cache.incrementalReuseCountForTesting, 1)
        XCTAssertEqual(second.messageKey, "assistant:render")
        XCTAssertTrue(second.blocks.contains { block in
            if case let .codeBlock(language, code) = block.kind {
                return language == "swift" && code.contains("let b = 2")
            }
            return false
        })
    }

    func testThemeSwitchDuringStreamingDoesNotRebuildConversationData() throws {
        let suiteName = "ThemeStoreStreamingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let conversationStore = ConversationStore()
        let themeStore = ThemeStore(defaults: defaults)
        let sessionID = "sess_theme_streaming"
        let metadata = AgentEventMetadata(
            seq: 12,
            sessionID: sessionID,
            turnID: "turn_theme",
            itemID: "assistant_theme",
            messageID: "message_theme",
            clientMessageID: nil,
            revision: 1,
            createdAt: nil
        )

        conversationStore.applyAssistantDelta(
            AgentDelta(text: "```swift\nlet theme = \"dark\"\n```", role: .assistant, kind: .message),
            metadata: metadata,
            fallbackSessionID: sessionID
        )
        let beforeMessages = conversationStore.messages(for: sessionID)
        let beforePlan = try XCTUnwrap(beforeMessages.first).renderFingerprint
        let renderPlan = MessageRenderPlanCache(limit: 4).plan(for: try XCTUnwrap(beforeMessages.first))

        themeStore.mode = .dark
        themeStore.preset = .gruvbox
        themeStore.uiFontPreset = .rounded
        themeStore.setFontScale(1.2)

        let afterMessages = conversationStore.messages(for: sessionID)
        XCTAssertEqual(afterMessages.map(\.id), beforeMessages.map(\.id))
        XCTAssertEqual(afterMessages.map(\.stableID), beforeMessages.map(\.stableID))
        XCTAssertEqual(try XCTUnwrap(afterMessages.first).renderFingerprint, beforePlan)
        XCTAssertEqual(conversationStore.lastSeenSeq(for: sessionID), 12)
        XCTAssertEqual(MessageRenderPlanCache(limit: 4).plan(for: try XCTUnwrap(afterMessages.first)).blocks, renderPlan.blocks)
    }

    func testEventReducerActorProducesBatchedStoreMutations() async {
        let reducer = EventReducer()
        let metadata = AgentEventMetadata(
            seq: 44,
            sessionID: "sess_reducer",
            turnID: "turn_reducer",
            itemID: "item_reducer",
            messageID: "message_reducer",
            clientMessageID: nil,
            revision: 2,
            createdAt: nil
        )

        let output = await reducer.reduce(
            .assistantDelta(AgentDelta(text: "后台 reducer 输出 mutation", role: .assistant, kind: .message), metadata),
            fallbackSessionID: "fallback",
            outputIdleClearDelay: 80_000_000
        )

        XCTAssertEqual(output.foregroundUpdates.count, 1)
        XCTAssertEqual(output.activeTurnMutations.count, 1)
        XCTAssertEqual(output.logAppends.count, 0)
        XCTAssertEqual(output.messageMutations.count, 1)
        if case .assistantDelta(let delta, let returnedMetadata, let fallbackSessionID) = output.messageMutations[0] {
            XCTAssertEqual(delta.text, "后台 reducer 输出 mutation")
            XCTAssertEqual(returnedMetadata.seq, 44)
            XCTAssertEqual(fallbackSessionID, "fallback")
        } else {
            XCTFail("Expected assistant delta mutation")
        }
    }

    func testLargeDiffPanelItemsDeduplicateAndCollapseTail() throws {
        let old = ConversationMessage(
            role: .system,
            kind: .fileChangeSummary,
            content: "文件变更：Sources/App.swift modified\n旧 diff",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let longBody = String(repeating: "+ changed line\n", count: 180) + "tail-marker"
        let latest = ConversationMessage(
            role: .system,
            kind: .fileChangeSummary,
            content: "文件变更：Sources/App.swift modified\n\(longBody)",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let other = ConversationMessage(
            role: .system,
            kind: .fileChangeSummary,
            content: "文件变更：Sources/Other.swift added\nsmall diff",
            createdAt: Date(timeIntervalSince1970: 15)
        )

        let items = DiffPanelItem.items(from: [old, latest, other])
        let appItem = try XCTUnwrap(items.first { $0.fileKey == "Sources/App.swift" })

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(appItem.count, 2)
        XCTAssertEqual(appItem.title, "文件变更 x2")
        XCTAssertTrue(appItem.wasCollapsed)
        XCTAssertLessThanOrEqual(appItem.latestContent.count, 1_200)
        XCTAssertTrue(appItem.latestContent.hasSuffix("tail-marker"))
        XCTAssertTrue(appItem.displaySubtitle.contains("已折叠长 diff"))
    }

    func testComposerStateRapidTypingDoesNotPublishGlobalStores() {
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        var conversationPublishCount = 0
        var logPublishCount = 0
        let conversationCancellable = conversationStore.objectWillChange.sink {
            conversationPublishCount += 1
        }
        let logCancellable = logStore.objectWillChange.sink {
            logPublishCount += 1
        }

        var composerState = ComposerState()
        for _ in 0..<500 {
            composerState.draft.append("字")
        }

        XCTAssertEqual(composerState.draft.count, 500)
        XCTAssertTrue(composerState.canSubmit(isLoading: false))
        XCTAssertEqual(conversationPublishCount, 0)
        XCTAssertEqual(logPublishCount, 0)
        withExtendedLifetime((conversationCancellable, logCancellable)) {}
    }

    func testComposerStateTracksSubmitEligibilityWithoutTrimmingDraft() {
        var composerState = ComposerState()

        composerState.draft = " \n\t "
        XCTAssertFalse(composerState.canSubmit(isLoading: false))

        composerState.draft = " \n\t 执行一次诊断"
        XCTAssertTrue(composerState.canSubmit(isLoading: false))
        XCTAssertFalse(composerState.canSubmit(isLoading: true))

        _ = composerState.takeDraftForSubmit(isLoading: false)
        XCTAssertEqual(composerState.draft, "")
        XCTAssertFalse(composerState.canSubmit(isLoading: false))

        composerState.restore("继续检查输入卡顿")
        XCTAssertTrue(composerState.canSubmit(isLoading: false))
    }

    func testComposerStateBuildsStructuredPayloadAndRestoresAttachments() throws {
        var composerState = ComposerState()
        composerState.draft = "看下这张图"
        composerState.addAttachment(.image(url: "data:image/png;base64,AA==", detail: .high))
        composerState.addAttachment(.mention(name: "README", path: "/tmp/project/README.md"))
        composerState.turnOptions.model = "gpt-5-codex"
        composerState.turnOptions.reasoningEffort = .high

        let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(isLoading: false))

        XCTAssertTrue(composerState.draft.isEmpty)
        XCTAssertTrue(composerState.attachments.isEmpty)
        XCTAssertEqual(submitted.payload.textPrompt, "看下这张图")
        XCTAssertEqual(submitted.payload.input.count, 3)
        XCTAssertEqual(submitted.payload.options.model, "gpt-5-codex")
        XCTAssertEqual(submitted.payload.options.reasoningEffort, .high)

        composerState.restore(submitted)
        XCTAssertEqual(composerState.draft, "看下这张图")
        XCTAssertEqual(composerState.attachments.count, 2)
        XCTAssertTrue(composerState.canSubmit(isLoading: false))
    }

    func testComposerPermissionModeAppliesSafePresets() {
        var composerState = ComposerState()

        composerState.applyPermissionMode(.readOnly)
        XCTAssertEqual(composerState.permissionMode, .readOnly)
        XCTAssertEqual(composerState.turnOptions.approvalPolicy, .onRequest)
        XCTAssertEqual(composerState.turnOptions.approvalsReviewer, "user")
        XCTAssertEqual(composerState.turnOptions.sandboxMode, .readOnly)
        XCTAssertFalse(composerState.turnOptions.networkAccess)

        composerState.applyPermissionMode(.autoApprove)
        XCTAssertEqual(composerState.permissionMode, .autoApprove)
        XCTAssertEqual(composerState.turnOptions.approvalPolicy, .onFailure)
        XCTAssertEqual(composerState.turnOptions.approvalsReviewer, "auto_review")
        XCTAssertEqual(composerState.turnOptions.sandboxMode, .workspaceWrite)
        XCTAssertFalse(composerState.turnOptions.networkAccess)

        composerState.applyPermissionMode(.requestApproval)
        XCTAssertEqual(composerState.permissionMode, .requestApproval)
        XCTAssertEqual(composerState.turnOptions.approvalPolicy, .onRequest)
        XCTAssertEqual(composerState.turnOptions.approvalsReviewer, "user")
        XCTAssertEqual(composerState.turnOptions.sandboxMode, .workspaceWrite)

        composerState.applyPermissionMode(.fullAccess)
        XCTAssertEqual(composerState.permissionMode, .fullAccess)
        XCTAssertEqual(composerState.turnOptions.approvalPolicy, .onRequest)
        XCTAssertEqual(composerState.turnOptions.approvalsReviewer, "user")
        XCTAssertEqual(composerState.turnOptions.sandboxMode, .dangerFullAccess)
        XCTAssertFalse(composerState.turnOptions.networkAccess)
    }

    func testComposerCanInitializeWithGlobalDefaultPermissionMode() {
        let composerState = ComposerState(defaultPermissionMode: .requestApproval)

        XCTAssertEqual(composerState.permissionMode, .requestApproval)
        XCTAssertEqual(composerState.turnOptions.approvalPolicy, .onRequest)
        XCTAssertEqual(composerState.turnOptions.approvalsReviewer, "user")
        XCTAssertEqual(composerState.turnOptions.sandboxMode, .workspaceWrite)
        XCTAssertFalse(composerState.turnOptions.networkAccess)
        XCTAssertEqual(ComposerPermissionMode.stored("missing"), .fullAccess)
    }

    func testComposerDefaultsToFullAccessWithApproval() {
        let composerState = ComposerState()

        XCTAssertNil(composerState.turnOptions.model)
        XCTAssertEqual(composerState.turnOptions.reasoningEffort, .xhigh)
        XCTAssertEqual(composerState.permissionMode, .fullAccess)
        XCTAssertEqual(composerState.turnOptions.approvalPolicy, .onRequest)
        XCTAssertEqual(composerState.turnOptions.approvalsReviewer, "user")
        XCTAssertEqual(composerState.turnOptions.sandboxMode, .dangerFullAccess)
        XCTAssertFalse(composerState.turnOptions.networkAccess)
    }

    func testComposerStateResetsTransientSendModeForSessionSwitch() {
        var composerState = ComposerState()

        composerState.toggleGoalMode()
        XCTAssertTrue(composerState.isGoalModeSelected)
        composerState.resetTransientSendMode()
        XCTAssertFalse(composerState.isGoalModeSelected)
        XCTAssertEqual(composerState.sendMode, .standard)

        composerState.togglePlanMode()
        XCTAssertTrue(composerState.isPlanModeSelected)
        composerState.resetTransientSendMode()
        XCTAssertFalse(composerState.isPlanModeSelected)
        XCTAssertEqual(composerState.sendMode, .standard)
    }

    func testComposerDraftCacheKeepsDraftsScopedToSessionOrNewProject() {
        let sessionScope = ComposerDraftScopeKey.current(selectedSessionID: "thread-a", selectedProjectID: "project-1")
        let newProjectScope = ComposerDraftScopeKey.current(selectedSessionID: nil, selectedProjectID: "project-1")
        var cache = ComposerDraftCache()
        let sessionDraft = ComposerDraftSnapshot(
            text: "只属于 thread-a 的草稿",
            attachments: [.mention(name: "README", path: "/repo/README.md")],
            voiceDraftNeedsReview: false
        )
        let projectDraft = ComposerDraftSnapshot(
            text: "项目新会话草稿",
            attachments: [],
            voiceDraftNeedsReview: true
        )

        cache.save(sessionDraft, for: sessionScope)
        cache.save(projectDraft, for: newProjectScope)

        XCTAssertEqual(cache.snapshot(for: sessionScope), sessionDraft)
        XCTAssertEqual(cache.snapshot(for: newProjectScope), projectDraft)
        XCTAssertEqual(
            cache.snapshot(for: .session("thread-b")),
            .empty,
            "切到其他会话时不能复用上一个输入框里的草稿"
        )

        cache.save(.empty, for: sessionScope)
        XCTAssertEqual(cache.snapshot(for: sessionScope), .empty)
    }

    func testComposerPlanAndGoalModesDoNotUseGuidedDelivery() {
        var composerState = ComposerState()

        XCTAssertEqual(
            composerState.runningTurnDelivery(canUseGuidedFollowUp: true, guidedFollowUpEnabled: true),
            .guided
        )

        composerState.togglePlanMode()
        XCTAssertEqual(
            composerState.runningTurnDelivery(canUseGuidedFollowUp: true, guidedFollowUpEnabled: true),
            .queued
        )

        composerState.resetTransientSendMode()
        composerState.toggleGoalMode()
        XCTAssertEqual(
            composerState.runningTurnDelivery(canUseGuidedFollowUp: true, guidedFollowUpEnabled: true),
            .queued
        )
    }

    func testComposerStateCanSubmitWithStandardModeSanitizedOptions() throws {
        var composerState = ComposerState()
        composerState.draft = "用标准模式提交"
        composerState.turnOptions.runtimeProvider = "claude"
        composerState.turnOptions.model = "gpt-5-codex"
        composerState.turnOptions.modelProvider = "openai"
        composerState.turnOptions.serviceTier = "priority"
        composerState.turnOptions.reasoningEffort = .high
        composerState.turnOptions.reasoningSummary = .detailed
        composerState.turnOptions.personality = .friendly
        composerState.turnOptions.approvalPolicy = .onFailure
        composerState.turnOptions.approvalsReviewer = "auto_review"
        composerState.turnOptions.sandboxMode = .readOnly
        composerState.turnOptions.networkAccess = true
        composerState.turnOptions.config = .object(["approval_policy": .string("never")])
        composerState.turnOptions.baseInstructions = "base"
        composerState.turnOptions.developerInstructions = "dev"
        composerState.turnOptions.outputSchema = .object(["type": .string("object")])
        composerState.turnOptions.serviceName = "ios"
        composerState.turnOptions.sessionStartSource = "ipad"
        composerState.turnOptions.threadSource = "user"

        let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: composerState.turnOptions.sanitizedForStandardComposer()
        ))
        let options = submitted.payload.options

        XCTAssertEqual(options.runtimeProvider, "claude")
        XCTAssertEqual(options.model, "gpt-5-codex")
        XCTAssertNil(options.modelProvider)
        XCTAssertEqual(options.serviceTier, "priority")
        XCTAssertEqual(options.reasoningEffort, .high)
        XCTAssertEqual(options.reasoningSummary, .detailed)
        XCTAssertEqual(options.personality, .friendly)
        XCTAssertEqual(options.approvalPolicy, .onRequest)
        XCTAssertEqual(options.approvalsReviewer, "user")
        XCTAssertEqual(options.sandboxMode, .readOnly)
        XCTAssertFalse(options.networkAccess)
        XCTAssertNil(options.config)
        XCTAssertNil(options.baseInstructions)
        XCTAssertNil(options.developerInstructions)
        XCTAssertNil(options.outputSchema)
        XCTAssertNil(options.serviceName)
        XCTAssertNil(options.sessionStartSource)
        XCTAssertNil(options.threadSource)
        XCTAssertEqual(options.collaborationMode, .default)
        XCTAssertFalse(options.planGuidanceEnabled)
    }

    func testComposerStateStandardModePreservesAutoApprovalPreset() throws {
        var composerState = ComposerState()
        composerState.draft = "用替我审批提交"
        composerState.applyPermissionMode(.autoApprove)
        composerState.turnOptions.networkAccess = true
        composerState.turnOptions.config = .object(["feature": .bool(true)])

        let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: composerState.turnOptions.sanitizedForStandardComposer()
        ))
        let options = submitted.payload.options

        XCTAssertEqual(options.approvalPolicy, .onFailure)
        XCTAssertEqual(options.approvalsReviewer, "auto_review")
        XCTAssertEqual(options.sandboxMode, .workspaceWrite)
        XCTAssertFalse(options.networkAccess)
        XCTAssertNil(options.config)
        XCTAssertEqual(options.collaborationMode, .default)
    }

    func testComposerStandardModeClearsPreviousPlanModeToDefault() throws {
        var options = CodexAppServerTurnOptions.default
        options.collaborationMode = .plan
        options.planGuidanceEnabled = true

        let standard = options.sanitizedForStandardComposer()

        XCTAssertEqual(standard.collaborationMode, .default)
        XCTAssertFalse(standard.planGuidanceEnabled)
    }

    func testComposerGoalSubmissionPayloadUsesDefaultCollaborationMode() throws {
        var composerState = ComposerState()
        composerState.draft = "完成目标任务"
        composerState.toggleGoalMode()
        var goalOptions = composerState.turnOptions.sanitizedForStandardComposer()
        // 目标模式的目标状态走 thread/goal/set；turn/start 必须显式回到 default。
        goalOptions.collaborationMode = .default
        goalOptions.planGuidanceEnabled = false

        let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: goalOptions
        ))

        XCTAssertEqual(submitted.payload.options.collaborationMode, .default)
        XCTAssertFalse(submitted.payload.options.planGuidanceEnabled)
    }

    func testConversationSendRegressionMatrixKeepsModesAttachmentsVoiceAndPermissionsIndependent() throws {
        var composerState = ComposerState()
        let projectPath = "/tmp/conversation-regression"

        composerState.draft = "先规划完整链路"
        composerState.togglePlanMode()
        composerState.addAttachment(.image(url: "https://example.test/diagram.png", detail: .high))
        composerState.addAttachment(.image(url: "data:image/png;base64,AA==", detail: .low))
        composerState.addAttachment(.localImage(path: "\(projectPath)/screen.png", detail: .original))
        composerState.addAttachment(.skill(name: "review", path: "\(projectPath)/.codex/skills/review/SKILL.md"))
        composerState.addAttachment(.mention(name: "README", path: "\(projectPath)/README.md"))
        var planOptions = composerState.turnOptions
        planOptions.collaborationMode = .plan
        planOptions.planGuidanceEnabled = true

        let planSubmission = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: planOptions
        ))
        XCTAssertEqual(planSubmission.payload.options.collaborationMode, .plan)
        XCTAssertTrue(planSubmission.payload.options.planGuidanceEnabled)
        XCTAssertEqual(planSubmission.payload.input.count, 6)
        XCTAssertEqual(planSubmission.payload.textPrompt, "先规划完整链路")
        XCTAssertTrue(payloadContainsImageURL(planSubmission.payload, url: "https://example.test/diagram.png"))
        XCTAssertTrue(payloadContainsInlineImage(planSubmission.payload))
        XCTAssertTrue(planSubmission.payload.input.contains {
            if case .localImage(let path, _) = $0 {
                return path == "\(projectPath)/screen.png"
            }
            return false
        })
        XCTAssertTrue(payloadContainsSkill(planSubmission.payload, name: "review"))
        XCTAssertTrue(payloadContainsMention(planSubmission.payload, name: "README"))

        // 回归：上一条 Plan 的本地 options 即使被沿用，普通发送也必须 sanitize 回 default。
        composerState.turnOptions = planSubmission.payload.options
        composerState.resetSendModeAfterSubmit()
        composerState.draft = "切回普通模式"
        let standardSubmission = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: composerState.turnOptions.sanitizedForStandardComposer()
        ))
        XCTAssertEqual(standardSubmission.payload.options.collaborationMode, .default)
        XCTAssertFalse(standardSubmission.payload.options.planGuidanceEnabled)
        XCTAssertEqual(standardSubmission.payload.textPrompt, "切回普通模式")

        composerState.restore("切到目标模式")
        composerState.toggleGoalMode()
        var goalOptions = composerState.turnOptions.sanitizedForStandardComposer()
        goalOptions.collaborationMode = .default
        goalOptions.planGuidanceEnabled = false
        let goalSubmission = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: goalOptions
        ))
        XCTAssertEqual(goalSubmission.payload.options.collaborationMode, .default)
        XCTAssertFalse(goalSubmission.payload.options.planGuidanceEnabled)
        XCTAssertEqual(
            composerState.runningTurnDelivery(canUseGuidedFollowUp: true, guidedFollowUpEnabled: true),
            .queued
        )

        composerState.resetSendModeAfterSubmit()
        composerState.beginVoiceInput()
        composerState.applyVoiceTranscript("语音目标任务")
        composerState.toggleGoalMode()
        let voiceGoalSubmission = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: composerState.turnOptions.sanitizedForStandardComposer()
        ))
        XCTAssertTrue(voiceGoalSubmission.voiceDraftNeedsReview)
        XCTAssertEqual(voiceGoalSubmission.payload.textPrompt, "语音目标任务")
        XCTAssertEqual(voiceGoalSubmission.payload.options.collaborationMode, .default)

        composerState.resetSendModeAfterSubmit()
        composerState.beginVoiceInput()
        composerState.applyVoiceTranscript("语音计划任务")
        composerState.togglePlanMode()
        var voicePlanOptions = composerState.turnOptions.sanitizedForStandardComposer()
        voicePlanOptions.collaborationMode = .plan
        voicePlanOptions.planGuidanceEnabled = true
        let voicePlanSubmission = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: voicePlanOptions
        ))
        XCTAssertTrue(voicePlanSubmission.voiceDraftNeedsReview)
        XCTAssertEqual(voicePlanSubmission.payload.options.collaborationMode, .plan)
        XCTAssertTrue(voicePlanSubmission.payload.options.planGuidanceEnabled)
    }

    func testComposerPermissionRegressionMatrixKeepsNetworkDisabled() throws {
        let cases: [(mode: ComposerPermissionMode, policy: CodexAppServerApprovalPolicy, reviewer: String, sandbox: CodexAppServerSandboxMode)] = [
            (.readOnly, .onRequest, "user", .readOnly),
            (.requestApproval, .onRequest, "user", .workspaceWrite),
            (.autoApprove, .onFailure, "auto_review", .workspaceWrite),
            (.fullAccess, .onRequest, "user", .dangerFullAccess)
        ]

        for testCase in cases {
            var composerState = ComposerState()
            composerState.draft = "权限矩阵 \(testCase.mode.rawValue)"
            composerState.applyPermissionMode(testCase.mode)
            composerState.turnOptions.networkAccess = true

            let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(
                isLoading: false,
                turnOptionsOverride: composerState.turnOptions.sanitizedForStandardComposer()
            ))
            let options = submitted.payload.options
            XCTAssertEqual(options.approvalPolicy, testCase.policy, "mode=\(testCase.mode)")
            XCTAssertEqual(options.approvalsReviewer, testCase.reviewer, "mode=\(testCase.mode)")
            XCTAssertEqual(options.sandboxMode, testCase.sandbox, "mode=\(testCase.mode)")
            // 移动端所有权限预设都不打开 networkAccess，避免一次发送把网络权限带进 app-server。
            XCTAssertFalse(options.networkAccess, "mode=\(testCase.mode)")
            XCTAssertEqual(options.collaborationMode, .default, "mode=\(testCase.mode)")
        }
    }

    func testComposerStateStandardModePreservesFullAccessPreset() throws {
        var composerState = ComposerState()
        composerState.draft = "用完全访问提交"
        composerState.applyPermissionMode(.fullAccess)
        composerState.turnOptions.networkAccess = true
        composerState.turnOptions.config = .object(["feature": .bool(true)])

        let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(
            isLoading: false,
            turnOptionsOverride: composerState.turnOptions.sanitizedForStandardComposer()
        ))
        let options = submitted.payload.options

        XCTAssertEqual(options.approvalPolicy, .onRequest)
        XCTAssertEqual(options.approvalsReviewer, "user")
        XCTAssertEqual(options.sandboxMode, .dangerFullAccess)
        XCTAssertFalse(options.networkAccess)
        XCTAssertNil(options.config)
    }

    func testComposerStateVoiceTranscriptPreservesManualEditsDuringRecording() {
        var composerState = ComposerState()
        composerState.draft = "已有上下文"
        composerState.beginVoiceInput()
        composerState.applyVoiceTranscript("第一段")
        XCTAssertEqual(composerState.draft, "已有上下文\n第一段")
        XCTAssertTrue(composerState.voiceDraftNeedsReview)

        composerState.draft += "\n手动补充"
        composerState.applyVoiceTranscript("第二段")

        XCTAssertEqual(composerState.draft, "已有上下文\n第一段\n手动补充\n第二段")
        XCTAssertTrue(composerState.voiceDraftNeedsReview)
        composerState.endVoiceInput()
    }

    func testComposerStateVoiceDraftRequiresReviewUntilSubmitted() throws {
        var composerState = ComposerState()
        XCTAssertFalse(composerState.voiceDraftNeedsReview)

        composerState.beginVoiceInput()
        composerState.applyVoiceTranscript("重启后端服务")

        XCTAssertEqual(composerState.draft, "重启后端服务")
        XCTAssertTrue(composerState.voiceDraftNeedsReview)

        let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(isLoading: false))

        XCTAssertTrue(submitted.voiceDraftNeedsReview)
        XCTAssertFalse(composerState.voiceDraftNeedsReview)

        composerState.restore(submitted)
        XCTAssertTrue(composerState.voiceDraftNeedsReview)

        composerState.draft = ""
        XCTAssertFalse(composerState.voiceDraftNeedsReview)
    }

    func testComposerStateVoiceReviewFlagDoesNotLeakIntoTypedRestore() throws {
        var composerState = ComposerState()
        composerState.beginVoiceInput()
        composerState.applyVoiceTranscript("检查发布文案")
        XCTAssertTrue(composerState.voiceDraftNeedsReview)

        composerState.restore("手动输入的新任务")

        XCTAssertEqual(composerState.draft, "手动输入的新任务")
        XCTAssertFalse(composerState.voiceDraftNeedsReview)

        let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(isLoading: false))
        XCTAssertFalse(submitted.voiceDraftNeedsReview)
    }

    func testVoiceInputLanguageStoresSafeDefaultAndLocaleCandidates() {
        XCTAssertEqual(VoiceInputLanguage.stored("missing"), .automatic)
        XCTAssertEqual(VoiceInputLanguage.stored(VoiceInputLanguage.englishUS.rawValue), .englishUS)
        XCTAssertEqual(VoiceInputLanguage.englishUS.localeCandidates.first?.identifier, "en_US")
        XCTAssertEqual(VoiceInputLanguage.chineseSimplified.localeCandidates.first?.identifier, "zh_CN")
        XCTAssertNil(VoiceInputLanguage.automatic.transcriptionLanguageCode)
        XCTAssertEqual(VoiceInputLanguage.chineseSimplified.transcriptionLanguageCode, "zh")
    }

    func testTextSelectionPolicyMovesExternalAppendCaretToEnd() {
        let first = TextSelectionPolicy.rangeAfterExternalTextSync(
            previousText: "",
            nextText: "第一段",
            previousRange: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(first.location, ("第一段" as NSString).length)
        XCTAssertEqual(first.length, 0)

        let previous = "第一段"
        let next = "第一段\n第二段"
        let second = TextSelectionPolicy.rangeAfterExternalTextSync(
            previousText: previous,
            nextText: next,
            previousRange: NSRange(location: (previous as NSString).length, length: 0)
        )
        XCTAssertEqual(second.location, (next as NSString).length)
        XCTAssertEqual(second.length, 0)
    }

    func testTextSelectionPolicyPreservesMiddleCaretForEndpointEditing() {
        let endpoint = "http://192.168.1.20:8787"
        let range = TextSelectionPolicy.rangeAfterExternalTextSync(
            previousText: endpoint,
            nextText: endpoint,
            previousRange: NSRange(location: 12, length: 0)
        )

        XCTAssertEqual(range.location, 12)
        XCTAssertEqual(range.length, 0)
    }

    func testVoiceWaveformLevelMappingBoostsQuietSpeechWithoutAnimatingSilence() {
        XCTAssertEqual(VoiceWaveformLevelMapping.visualLevel(for: 0), 0, accuracy: 0.001)
        XCTAssertEqual(VoiceWaveformLevelMapping.visualLevel(for: 0.02), 0, accuracy: 0.001)

        let quiet = VoiceWaveformLevelMapping.visualLevel(for: 0.10)
        let normal = VoiceWaveformLevelMapping.visualLevel(for: 0.35)
        let loud = VoiceWaveformLevelMapping.visualLevel(for: 0.75)

        XCTAssertGreaterThan(quiet, 0.30)
        XCTAssertGreaterThan(normal, quiet)
        XCTAssertGreaterThan(normal - quiet, 0.20)
        XCTAssertGreaterThan(loud, 0.85)
        XCTAssertLessThanOrEqual(VoiceWaveformLevelMapping.visualLevel(for: 2), 1)
    }

    func testVoiceWaveformSampleShapeUsesCurrentLevelWithoutScrollingHistory() {
        let silence = VoiceWaveformSampleShape.samples(for: 0.01, count: 9)
        XCTAssertEqual(silence, Array(repeating: 0, count: 9))

        let first = VoiceWaveformSampleShape.samples(for: 0.45, count: 9)
        let second = VoiceWaveformSampleShape.samples(for: 0.45, count: 9)

        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(first[4], first[0])
        XCTAssertGreaterThan(first[4], first[8])
        XCTAssertEqual(first[0], first[8], accuracy: 0.001)
        XCTAssertEqual(first[1], first[7], accuracy: 0.001)
    }

    func testRuntimeActivityDisplayTiersExposeLastEventEvidence() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = RuntimeActivitySnapshot(
            turnStartedAt: startedAt,
            lastActivityAt: startedAt.addingTimeInterval(70)
        )

        let fresh = RuntimeActivityDisplay.make(
            snapshot: snapshot,
            webSocketStatus: .connected,
            now: startedAt.addingTimeInterval(80)
        )
        XCTAssertEqual(fresh?.tone, .active)
        XCTAssertEqual(fresh?.detailText, "运行 01:20 · 最后活动 10 秒前")

        let waiting = RuntimeActivityDisplay.make(
            snapshot: snapshot,
            webSocketStatus: .connected,
            now: startedAt.addingTimeInterval(140)
        )
        XCTAssertEqual(waiting?.tone, .neutral)
        XCTAssertTrue(waiting?.detailText.contains("等待输出") == true)

        let stale = RuntimeActivityDisplay.make(
            snapshot: snapshot,
            webSocketStatus: .connected,
            now: startedAt.addingTimeInterval(180)
        )
        XCTAssertEqual(stale?.tone, .warning)
        XCTAssertTrue(stale?.detailText.contains("连接正常") == true)

        let disconnected = RuntimeActivityDisplay.make(
            snapshot: snapshot,
            webSocketStatus: .disconnected,
            now: startedAt.addingTimeInterval(80)
        )
        XCTAssertEqual(disconnected?.tone, .warning)
        XCTAssertTrue(disconnected?.detailText.contains("连接断开") == true)
    }

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

    func testDirectAppServerHistoryDeduplicatesLiveCompletedAssistantItem() {
        let store = ConversationStore()
        let sessionID = "thread_direct_dedup"
        let turnID = "turn_direct_dedup"
        let itemID = "assistant_direct_dedup"
        let stableID = "appserver:\(turnID):\(itemID)"
        let answer = "有。\n\n程序员结婚后第一次吵架。"
        let metadata = AgentEventMetadata(
            seq: 1,
            sessionID: sessionID,
            turnID: turnID,
            itemID: itemID,
            messageID: stableID,
            clientMessageID: nil,
            revision: 1,
            createdAt: nil
        )

        store.completeMessage(
            AgentMessage(
                id: stableID,
                sessionID: sessionID,
                turnID: turnID,
                itemID: itemID,
                role: .assistant,
                content: answer,
                createdAt: Date(timeIntervalSince1970: 20),
                seq: 1,
                revision: 1,
                sendStatus: .confirmed
            ),
            metadata: metadata,
            fallbackSessionID: sessionID
        )

        store.setHistory([
            CodexHistoryMessage(
                id: itemID,
                role: "assistant",
                content: answer,
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: itemID,
                revision: 1,
                sendStatus: .confirmed
            )
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.stableID, stableID)
        XCTAssertEqual(messages.first?.turnID, turnID)
        XCTAssertEqual(messages.first?.itemID, itemID)
        XCTAssertEqual(messages.first?.content, answer)
    }

    func testHistoryDeduplicatesLiveAssistantWhenThreadReadRenumbersItemID() {
        // 复刻真实抓包：流式 item/completed 用 app-server 真实 id(msg_…)，而 thread/read 把同一条助手
        // 消息重排成整条线程的全局顺序号(item-N)；turnId 与最终文本两边一致。手动刷新时必须合并为一条。
        let store = ConversationStore()
        let sessionID = "thread_renumber"
        let turnID = "019ea77f-608a-7be0-9ae1-3bf9d3421370"
        let liveItemID = "msg_0457a91708aef848016a26c89602288195938ee282e5218165"
        let historyItemID = "item-8"
        let answer = "面试官：“你最大的缺点是什么？”\n\n程序员：“太诚实。”"

        store.completeMessage(
            AgentMessage(
                id: "appserver:\(turnID):\(liveItemID)",
                sessionID: sessionID,
                turnID: turnID,
                itemID: liveItemID,
                role: .assistant,
                content: answer,
                createdAt: Date(timeIntervalSince1970: 20),
                seq: 1,
                revision: 1,
                sendStatus: .confirmed
            ),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: turnID,
                itemID: liveItemID,
                messageID: "appserver:\(turnID):\(liveItemID)",
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):\(historyItemID)",
                role: "assistant",
                content: answer,
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: historyItemID,
                revision: 1,
                sendStatus: .confirmed,
                isTimestampFallback: true
            )
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1, "itemId 不一致(msg_… vs item-N)但 turnId+文本一致时应合并为一条，而不是刷新后重复")
        XCTAssertEqual(messages.first?.role, .assistant)
        XCTAssertEqual(messages.first?.content, answer)
    }

    func testHistoryDeduplicatesLiveProcessMessagesWhenThreadReadRenumbersItemID() throws {
        // 过程卡和最终 assistant 一样会遇到 thread/read 重排 item id；同一 turn、同一类过程卡、
        // 同一文本应保留历史快照，丢弃 websocket replay 的直播副本。
        let store = ConversationStore()
        let sessionID = "thread_process_renumber"
        let turnID = "turn_process_renumber"
        let liveItemID = "msg_live_reasoning"
        let historyItemID = "item-5"
        let summary = "我先确认历史数据与实时 replay 的边界。"

        store.completeMessage(
            AgentMessage(
                id: "appserver:\(turnID):\(liveItemID)",
                sessionID: sessionID,
                turnID: turnID,
                itemID: liveItemID,
                role: .system,
                kind: .reasoningSummary,
                content: summary,
                createdAt: Date(timeIntervalSince1970: 20),
                seq: 1,
                revision: 1,
                sendStatus: .confirmed
            ),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: turnID,
                itemID: liveItemID,
                messageID: "appserver:\(turnID):\(liveItemID)",
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):\(historyItemID)",
                role: "system",
                kind: .reasoningSummary,
                content: summary,
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: historyItemID,
                revision: 1,
                sendStatus: .confirmed,
                isTimestampFallback: true
            )
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertEqual(messages.first?.kind, .reasoningSummary)
        XCTAssertEqual(messages.first?.content, summary)
        XCTAssertEqual(messages.first?.createdAt, Date(timeIntervalSince1970: 20), "去重后应保留 history 身份，但回填 live 真实时间，避免历史刷新把过程项拖回 turn.startedAt")
        XCTAssertFalse(try XCTUnwrap(messages.first).isTimestampFallback)
    }

    func testHistoryMergePlacesLiveOnlyCommandBetweenEstimatedHistoryNeighbors() {
        let store = ConversationStore()
        let sessionID = "thread_live_command_order"
        let turnID = "turn_live_command_order"

        store.appendSystem(
            "命令：grep -n activeTurnID",
            sessionID: sessionID,
            kind: .commandSummary,
            metadata: AgentEventMetadata(
                seq: 2,
                sessionID: sessionID,
                turnID: turnID,
                itemID: "cmd_live_only",
                messageID: "cmd_live_only",
                clientMessageID: nil,
                revision: 1,
                createdAt: Date(timeIntervalSince1970: 20)
            )
        )
        store.setHistory([
            CodexHistoryMessage(
                id: "user_history_order",
                role: "user",
                content: "先排查",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "user_history_order",
                timelineOrdinal: 0,
                isTimestampFallback: true
            ),
            CodexHistoryMessage(
                id: "plan_history_order",
                role: "system",
                kind: .plan,
                content: "修复历史排序",
                createdAt: Date(timeIntervalSince1970: 30),
                turnID: turnID,
                itemID: "plan_history_order",
                timelineOrdinal: 2,
                isTimestampFallback: true
            )
        ], sessionID: sessionID)

        XCTAssertEqual(
            store.messages(for: sessionID).map(\.content),
            ["先排查", "命令：grep -n activeTurnID", "修复历史排序"]
        )
    }

    func testAuthoritativeCompletedHistoryPrunesMissingProjectedProcessItems() {
        let store = ConversationStore()
        let sessionID = "thread_projected_orphan_prune"
        let turnID = "turn_projected_orphan_prune"

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-1",
                role: "user",
                content: "检查排序",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-1",
                timelineOrdinal: 1
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-20",
                role: "system",
                kind: .plan,
                content: "给出修复计划",
                createdAt: Date(timeIntervalSince1970: 20),
                turnID: turnID,
                itemID: "item-20",
                timelineOrdinal: 20
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-21",
                role: "system",
                kind: .commandSummary,
                content: "命令：git diff",
                createdAt: Date(timeIntervalSince1970: 10.021),
                turnID: turnID,
                itemID: "item-21",
                timelineOrdinal: 21,
                isTimestampFallback: true
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-22",
                role: "system",
                kind: .commandSummary,
                content: "命令：grep -n ConversationStore",
                createdAt: Date(timeIntervalSince1970: 10.022),
                turnID: turnID,
                itemID: "item-22",
                timelineOrdinal: 22,
                isTimestampFallback: true
            )
        ], sessionID: sessionID)
        XCTAssertEqual(store.messages(for: sessionID).filter { $0.kind == .commandSummary }.count, 2)

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-1",
                role: "user",
                content: "检查排序",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-1",
                timelineOrdinal: 1
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-20",
                role: "system",
                kind: .plan,
                content: "给出修复计划",
                createdAt: Date(timeIntervalSince1970: 20),
                turnID: turnID,
                itemID: "item-20",
                timelineOrdinal: 20
            )
        ], sessionID: sessionID, authoritativeCompletedTurnItems: [
            turnID: ["item-1", "item-20"]
        ])

        XCTAssertEqual(store.messages(for: sessionID).map(\.content), ["检查排序", "给出修复计划"])
        XCTAssertFalse(store.messages(for: sessionID).contains { $0.itemID == "item-21" || $0.itemID == "item-22" })
    }

    func testAuthoritativeCompletedHistoryKeepsLiveProcessItemsWithoutTimelineOrdinal() {
        let store = ConversationStore()
        let sessionID = "thread_live_process_preserve"
        let turnID = "turn_live_process_preserve"

        store.appendSystem(
            "命令：git diff",
            sessionID: sessionID,
            kind: .commandSummary,
            metadata: AgentEventMetadata(
                seq: 2,
                sessionID: sessionID,
                turnID: turnID,
                itemID: "cmd_live_1",
                messageID: "appserver:\(turnID):cmd_live_1",
                clientMessageID: nil,
                revision: 1,
                createdAt: Date(timeIntervalSince1970: 15)
            )
        )

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-1",
                role: "user",
                content: "检查排序",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-1",
                timelineOrdinal: 1
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-20",
                role: "system",
                kind: .plan,
                content: "给出修复计划",
                createdAt: Date(timeIntervalSince1970: 20),
                turnID: turnID,
                itemID: "item-20",
                timelineOrdinal: 20
            )
        ], sessionID: sessionID, authoritativeCompletedTurnItems: [
            turnID: ["item-1", "item-20"]
        ])

        let messages = store.messages(for: sessionID)
        XCTAssertTrue(messages.contains { $0.itemID == "cmd_live_1" && $0.timelineOrdinal == nil })
        XCTAssertEqual(messages.map(\.content), ["检查排序", "命令：git diff", "给出修复计划"])
    }

    func testSummaryHistoryDoesNotPruneMissingProjectedProcessItems() {
        let store = ConversationStore()
        let sessionID = "thread_summary_no_prune"
        let turnID = "turn_summary_no_prune"

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-1",
                role: "user",
                content: "检查排序",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-1",
                timelineOrdinal: 1
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-21",
                role: "system",
                kind: .commandSummary,
                content: "命令：git diff",
                createdAt: Date(timeIntervalSince1970: 10.021),
                turnID: turnID,
                itemID: "item-21",
                timelineOrdinal: 21,
                isTimestampFallback: true
            )
        ], sessionID: sessionID)

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-1",
                role: "user",
                content: "检查排序",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-1",
                timelineOrdinal: 1
            )
        ], sessionID: sessionID)

        XCTAssertTrue(store.messages(for: sessionID).contains { $0.itemID == "item-21" })
    }

    func testAuthoritativeCompletedHistoryKeepsProjectedProcessItemsPresentInTurnItemSet() {
        let store = ConversationStore()
        let sessionID = "thread_window_process_preserve"
        let turnID = "turn_window_process_preserve"

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-1",
                role: "user",
                content: "检查排序",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-1",
                timelineOrdinal: 1
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-30",
                role: "system",
                kind: .commandSummary,
                content: "工具：browser.open\n状态：completed",
                createdAt: Date(timeIntervalSince1970: 30),
                turnID: turnID,
                itemID: "item-30",
                timelineOrdinal: 30
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-31",
                role: "system",
                kind: .fileChangeSummary,
                content: "文件变更：Sources/App.swift",
                createdAt: Date(timeIntervalSince1970: 31),
                turnID: turnID,
                itemID: "item-31",
                timelineOrdinal: 31
            )
        ], sessionID: sessionID)

        // 核心逻辑：thread/read 兜底按消息切窗口，当前页可能没带这个工具卡；
        // 只要 runtime 的完整 turn item 集合证明它仍存在，就不能当 orphan 清理。
        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-1",
                role: "user",
                content: "检查排序",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-1",
                timelineOrdinal: 1
            )
        ], sessionID: sessionID, authoritativeCompletedTurnItems: [
            turnID: ["item-1", "item-30", "item-31"]
        ])

        XCTAssertTrue(store.messages(for: sessionID).contains { $0.itemID == "item-30" })
        XCTAssertTrue(store.messages(for: sessionID).contains { $0.itemID == "item-31" })
    }

    func testHistoryMergeDoesNotLetFallbackOrdinalTimePushAccurateProcessEventsBehind() throws {
        let store = ConversationStore()
        let sessionID = "thread_fallback_plan_before_accurate_command"
        let turnID = "turn_fallback_plan_before_accurate_command"

        store.setHistory([
            CodexHistoryMessage(
                id: "plan_fallback",
                role: "system",
                kind: .plan,
                content: "先列出修复计划。",
                createdAt: Date(timeIntervalSince1970: 38),
                turnID: turnID,
                itemID: "plan_fallback",
                timelineOrdinal: 2,
                isTimestampFallback: true
            ),
            CodexHistoryMessage(
                id: "cmd_accurate",
                role: "system",
                kind: .commandSummary,
                content: "命令：grep -n ConversationStore",
                createdAt: Date(timeIntervalSince1970: 32),
                turnID: turnID,
                itemID: "cmd_accurate",
                timelineOrdinal: 3
            )
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        // 橙色估算时间只能辅助排序，不能把灰色真实时间的历史过程卡压到后面。
        XCTAssertEqual(messages.map(\.content), ["命令：grep -n ConversationStore", "先列出修复计划。"])
        XCTAssertFalse(try XCTUnwrap(messages.first).isTimestampFallback)
        XCTAssertTrue(try XCTUnwrap(messages.last).isTimestampFallback)
    }

    func testReplayedLiveCompletionWithOlderTimestampSortsBeforeEstimatedPlan() {
        // 回放事故回归：merge 先落地（含橙色估算 plan），断线回放的命令卡随后带着更早的
        // 原始时间戳到达；它必须插回 plan 之前，而不是钉在时间线尾部。
        let store = ConversationStore()
        let sessionID = "thread_replay_after_merge"
        let turnID = "turn_replay_after_merge"

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-0",
                role: "user",
                content: "先排查",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-0",
                timelineOrdinal: 0
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-11",
                role: "system",
                kind: .plan,
                content: "# 修复计划",
                createdAt: Date(timeIntervalSince1970: 38),
                turnID: turnID,
                itemID: "item-11",
                timelineOrdinal: 11,
                isTimestampFallback: true
            )
        ], sessionID: sessionID)

        store.completeMessage(
            AgentMessage(
                id: "appserver:\(turnID):cmd_live",
                sessionID: sessionID,
                turnID: turnID,
                itemID: "cmd_live",
                role: .system,
                kind: .commandSummary,
                content: "命令：grep -n ConversationStore",
                createdAt: Date(timeIntervalSince1970: 32),
                seq: 9,
                revision: 9,
                sendStatus: .confirmed
            ),
            metadata: AgentEventMetadata(
                seq: 9,
                sessionID: sessionID,
                turnID: turnID,
                itemID: "cmd_live",
                messageID: "appserver:\(turnID):cmd_live",
                clientMessageID: nil,
                revision: 9,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        XCTAssertEqual(
            store.messages(for: sessionID).map(\.content),
            ["先排查", "命令：grep -n ConversationStore", "# 修复计划"],
            "回放追加的旧时间戳命令卡应插回估算 plan 之前"
        )
    }

    func testReplayedPlanCompletionBackfillsEstimatedHistoryTwinInsteadOfDuplicating() throws {
        // thread/read 把 plan item id 重排后，回放的 plan completed 带的是流式 id；
        // 同 turn 同文本时应回填历史孪生卡的真实时间，而不是再补一张重复卡。
        let store = ConversationStore()
        let sessionID = "thread_replay_plan_twin"
        let turnID = "turn_replay_plan_twin"
        let planText = "# 设置与连接入口收敛方案"

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-11",
                role: "system",
                kind: .plan,
                content: planText,
                createdAt: Date(timeIntervalSince1970: 38),
                turnID: turnID,
                itemID: "item-11",
                timelineOrdinal: 11,
                isTimestampFallback: true
            )
        ], sessionID: sessionID)

        store.completeMessage(
            AgentMessage(
                id: "appserver:\(turnID):plan_live",
                sessionID: sessionID,
                turnID: turnID,
                itemID: "plan_live",
                role: .system,
                kind: .plan,
                content: planText,
                createdAt: Date(timeIntervalSince1970: 41),
                seq: 12,
                revision: 12,
                sendStatus: .confirmed
            ),
            metadata: AgentEventMetadata(
                seq: 12,
                sessionID: sessionID,
                turnID: turnID,
                itemID: "plan_live",
                messageID: "appserver:\(turnID):plan_live",
                clientMessageID: nil,
                revision: 12,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1, "回放的 plan completed 应合并进历史孪生卡，而不是再补一张")
        let plan = try XCTUnwrap(messages.first)
        XCTAssertEqual(plan.kind, .plan)
        XCTAssertFalse(plan.isTimestampFallback, "live 真实时间应回填，估算标记要清除")
        XCTAssertEqual(plan.createdAt, Date(timeIntervalSince1970: 41))
        XCTAssertEqual(plan.sendStatus, .confirmed)
    }

    func testReplayedPlanTwinBackfillResortsAfterAccurateTimeArrives() {
        // 孪生卡回填真实时间后必须重新归位；否则 plan 这类估算时间卡会继续留在旧位置。
        let store = ConversationStore()
        let sessionID = "thread_replay_plan_twin_resort"
        let turnID = "turn_replay_plan_twin_resort"
        let planText = "# 修复计划"

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-2",
                role: "system",
                kind: .plan,
                content: planText,
                createdAt: Date(timeIntervalSince1970: 38),
                turnID: turnID,
                itemID: "item-2",
                timelineOrdinal: 2,
                isTimestampFallback: true
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-3",
                role: "system",
                kind: .commandSummary,
                content: "命令：go test ./...",
                createdAt: Date(timeIntervalSince1970: 32),
                turnID: turnID,
                itemID: "item-3",
                timelineOrdinal: 3
            )
        ], sessionID: sessionID)

        XCTAssertEqual(
            store.messages(for: sessionID).map(\.content),
            ["命令：go test ./...", planText]
        )

        store.completeMessage(
            AgentMessage(
                id: "appserver:\(turnID):plan_live",
                sessionID: sessionID,
                turnID: turnID,
                itemID: "plan_live",
                role: .system,
                kind: .plan,
                content: planText,
                createdAt: Date(timeIntervalSince1970: 31),
                seq: 12,
                revision: 12,
                sendStatus: .confirmed
            ),
            metadata: AgentEventMetadata(
                seq: 12,
                sessionID: sessionID,
                turnID: turnID,
                itemID: "plan_live",
                messageID: "appserver:\(turnID):plan_live",
                clientMessageID: nil,
                revision: 12,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        XCTAssertEqual(
            store.messages(for: sessionID).map(\.content),
            [planText, "命令：go test ./..."],
            "live 真实时间到达后，历史孪生卡应从估算位置回到真实时间线位置"
        )
    }

    func testHistoryMergeKeepsStableOrderWhenOrdinalAndLiveTimesConflict() {
        let store = ConversationStore()
        let sessionID = "thread_conflicting_timeline_order"
        let turnID = "turn_conflicting_timeline_order"

        store.appendSystem(
            "命令：sed -n '1,40p' EventReducer.swift",
            sessionID: sessionID,
            kind: .commandSummary,
            metadata: AgentEventMetadata(
                seq: 2,
                sessionID: sessionID,
                turnID: turnID,
                itemID: "cmd_live_conflict",
                messageID: "cmd_live_conflict",
                clientMessageID: nil,
                revision: 1,
                createdAt: Date(timeIntervalSince1970: 120)
            )
        )
        store.setHistory([
            CodexHistoryMessage(
                id: "plan_conflict",
                role: "system",
                kind: .plan,
                content: "先给出计划。",
                createdAt: Date(timeIntervalSince1970: 131),
                turnID: turnID,
                itemID: "plan_conflict",
                timelineOrdinal: 5
            ),
            CodexHistoryMessage(
                id: "user_conflict",
                role: "user",
                content: "要求后续变更",
                createdAt: Date(timeIntervalSince1970: 104),
                turnID: turnID,
                itemID: "user_conflict",
                timelineOrdinal: 6,
                userDelivery: .injected
            )
        ], sessionID: sessionID)

        XCTAssertEqual(
            store.messages(for: sessionID).map(\.content),
            ["命令：sed -n '1,40p' EventReducer.swift", "先给出计划。", "要求后续变更"]
        )
    }

    func testHistoryKeepsDistinctProcessMessagesInSameTurn() {
        let store = ConversationStore()
        let sessionID = "thread_process_distinct"
        let turnID = "turn_process_distinct"

        store.setHistory([
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-1",
                role: "system",
                kind: .reasoningSummary,
                content: "先读取本地实现。",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "item-1"
            ),
            CodexHistoryMessage(
                id: "appserver:\(turnID):item-2",
                role: "system",
                kind: .reasoningSummary,
                content: "再和 Codex CLI 对齐。",
                createdAt: Date(timeIntervalSince1970: 11),
                turnID: turnID,
                itemID: "item-2"
            )
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.map(\.content), ["先读取本地实现。", "再和 Codex CLI 对齐。"])
    }

    func testStructuredHistoryProcessMessagesCollapseBeforeFinalAssistantAndPinsPlanAfterAnswer() throws {
        let store = ConversationStore()
        let sessionID = "sess_history_processed"
        let turnID = "turn_history_processed"

        store.setHistory([
            CodexHistoryMessage(
                id: "user_history_processed",
                role: "user",
                content: "调用子 agent 讲个笑话",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "user_history_processed"
            ),
            CodexHistoryMessage(
                id: "commentary_history_processed",
                role: "system",
                kind: .reasoningSummary,
                content: "我先调用一个子 agent。",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: turnID,
                itemID: "commentary_history_processed"
            ),
            CodexHistoryMessage(
                id: "plan_history_processed",
                role: "system",
                kind: .plan,
                content: "让子 agent 生成一个短笑话。",
                createdAt: Date(timeIntervalSince1970: 12),
                turnID: turnID,
                itemID: "plan_history_processed"
            ),
            CodexHistoryMessage(
                id: "assistant_history_processed",
                role: "assistant",
                content: "程序员相亲，对方问：你会浪漫吗？",
                createdAt: Date(timeIntervalSince1970: 44),
                turnID: turnID,
                itemID: "assistant_history_processed"
            )
        ], sessionID: sessionID)

        let items = ConversationTimelineItemBuilder.items(from: store.messages(for: sessionID))

        XCTAssertEqual(items.count, 4)
        guard case .processed(let group) = items[1] else {
            return XCTFail("history 过程消息应该折叠到最终 assistant 前")
        }
        XCTAssertEqual(group.messages.map(\.content), ["我先调用一个子 agent。"])
        XCTAssertEqual(group.title, "已处理 1 步 · 34s")
        guard case .message(let final) = items[2] else {
            return XCTFail("最终 assistant 应保持独立展开")
        }
        XCTAssertEqual(final.role, .assistant)
        XCTAssertEqual(final.content, "程序员相亲，对方问：你会浪漫吗？")
        guard case .message(let plan) = items[3] else {
            return XCTFail("计划卡应固定在最终回答之后，作为一级卡片展示")
        }
        XCTAssertEqual(plan.kind, .plan)
        XCTAssertEqual(plan.content, "让子 agent 生成一个短笑话。")
    }

    func testHistoryDeduplicatesClientMessageEcho() {
        let store = ConversationStore()
        let sessionID = "sess_client_echo_history"
        let now = Date()

        store.appendLocalUser("讲个笑话", sessionID: sessionID, clientMessageID: "client-joke", sendStatus: .sent)
        store.setHistory([
            CodexHistoryMessage(role: "user", content: "讲个笑话", createdAt: now)
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .user)
        XCTAssertEqual(messages.first?.content, "讲个笑话")
    }

    func testConversationMessagesTrackCreatedAndCompletedTimes() throws {
        let store = ConversationStore()
        let sessionID = "sess_message_times"
        let startedAt = Date(timeIntervalSince1970: 100)
        let completedAt = Date(timeIntervalSince1970: 140)
        let startMetadata = AgentEventMetadata(
            seq: 1,
            sessionID: sessionID,
            turnID: "turn-times",
            itemID: "assistant-times",
            messageID: nil,
            clientMessageID: nil,
            revision: 1,
            createdAt: startedAt
        )

        store.applyAssistantDelta(
            AgentDelta(text: "正在处理", role: .assistant, kind: .message),
            metadata: startMetadata,
            fallbackSessionID: sessionID
        )

        var assistant = try XCTUnwrap(store.messages(for: sessionID).first)
        XCTAssertEqual(assistant.createdAt, startedAt)
        XCTAssertNil(assistant.updatedAt)

        let completionMetadata = AgentEventMetadata(
            seq: 2,
            sessionID: sessionID,
            turnID: "turn-times",
            itemID: "assistant-times",
            messageID: nil,
            clientMessageID: nil,
            revision: 2,
            createdAt: completedAt
        )
        store.markCurrentAssistantCompleted(metadata: completionMetadata, fallbackSessionID: sessionID)

        assistant = try XCTUnwrap(store.messages(for: sessionID).first)
        XCTAssertEqual(assistant.createdAt, startedAt)
        XCTAssertEqual(assistant.updatedAt, completedAt)

        store.setHistory([
            CodexHistoryMessage(
                id: "history-assistant-times",
                role: "assistant",
                content: "历史回复",
                createdAt: startedAt,
                updatedAt: completedAt,
                turnID: "history-turn",
                itemID: "history-assistant-times"
            )
        ], sessionID: "sess_history_message_times")

        let historyAssistant = try XCTUnwrap(store.messages(for: "sess_history_message_times").first)
        XCTAssertEqual(historyAssistant.createdAt, startedAt)
        XCTAssertEqual(historyAssistant.updatedAt, completedAt)
    }

    func testRepeatedUnstableHistoryProjectionKeepsMessageIdentity() {
        let store = ConversationStore()
        let sessionID = "sess_unstable_history_projection"
        let createdAt = Date(timeIntervalSince1970: 100)

        store.setHistory([
            CodexHistoryMessage(role: "user", content: "旧历史问题", createdAt: createdAt),
            CodexHistoryMessage(role: "assistant", content: "旧历史回答", createdAt: createdAt.addingTimeInterval(1))
        ], sessionID: sessionID)
        let firstIDs = store.messages(for: sessionID).map(\.id)

        // 上游历史项没有稳定 id 时，解码会补随机 UUID；语义相同的历史页重复绑定时，
        // 投影缓存应复用上一批 ConversationMessage，避免 SwiftUI 把整页当成新消息重绘。
        store.setHistory([
            CodexHistoryMessage(role: "user", content: "旧历史问题", createdAt: createdAt),
            CodexHistoryMessage(role: "assistant", content: "旧历史回答", createdAt: createdAt.addingTimeInterval(1))
        ], sessionID: sessionID)
        let replayed = store.messages(for: sessionID)

        XCTAssertEqual(replayed.map(\.id), firstIDs)
        XCTAssertEqual(replayed.map(\.content), ["旧历史问题", "旧历史回答"])
    }

    func testRepeatedIdenticalHistorySkipsMergeWork() {
        let store = ConversationStore()
        let sessionID = "sess_identical_history_fast_path"
        let createdAt = Date(timeIntervalSince1970: 150)
        let history = [
            CodexHistoryMessage(role: "user", content: "刷新问题", createdAt: createdAt),
            CodexHistoryMessage(role: "assistant", content: "刷新回答", createdAt: createdAt.addingTimeInterval(1))
        ]

        store.setHistory(history, sessionID: sessionID)
        XCTAssertEqual(store.historyMergeInvocationCountForTesting, 1)

        // 同一页历史重复刷新时，projection 已经能证明没有变化，不需要再次 merge/sort。
        store.setHistory(history, sessionID: sessionID)

        XCTAssertEqual(store.historyMergeInvocationCountForTesting, 1)
        XCTAssertTrue(store.hasLoadedHistory(sessionID: sessionID))
        XCTAssertEqual(store.messages(for: sessionID).map(\.content), ["刷新问题", "刷新回答"])
    }

    func testRepeatedLongHistoryProjectionSkipsMergeWork() {
        let store = ConversationStore()
        let sessionID = "sess_long_history_fast_path"
        let createdAt = Date(timeIntervalSince1970: 175)
        let longAnswer = String(repeating: "长回答内容", count: 8_000)
        let history = [
            CodexHistoryMessage(role: "user", content: "生成长回答", createdAt: createdAt),
            CodexHistoryMessage(role: "assistant", content: longAnswer, createdAt: createdAt.addingTimeInterval(1))
        ]

        store.setHistory(history, sessionID: sessionID)
        XCTAssertEqual(store.historyMergeInvocationCountForTesting, 1)

        // 长消息重复刷新时，Store 使用 content digest 判断等价，避免完整 content 参与热路径比较。
        store.setHistory(history, sessionID: sessionID)

        XCTAssertEqual(store.historyMergeInvocationCountForTesting, 1)
        XCTAssertEqual(store.messages(for: sessionID).last?.contentByteCount, longAnswer.utf8.count)
        XCTAssertEqual(store.messages(for: sessionID).last?.content, longAnswer)
    }

    func testGrowingUnstableHistoryProjectionReusesExistingRows() {
        let store = ConversationStore()
        let sessionID = "sess_growing_unstable_history"
        let createdAt = Date(timeIntervalSince1970: 200)
        let firstPage = [
            CodexHistoryMessage(role: "user", content: "第一轮问题", createdAt: createdAt),
            CodexHistoryMessage(role: "assistant", content: "第一轮回答", createdAt: createdAt.addingTimeInterval(1))
        ]

        store.setHistory(firstPage, sessionID: sessionID)
        let firstIDs = store.messages(for: sessionID).map(\.id)

        store.setHistory(firstPage + [
            CodexHistoryMessage(role: "assistant", content: "第二轮回答", createdAt: createdAt.addingTimeInterval(2))
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(Array(messages.prefix(2)).map(\.id), firstIDs)
        XCTAssertEqual(messages.map(\.content), ["第一轮问题", "第一轮回答", "第二轮回答"])
    }

    func testPrependingUndatedHistoryReusesExistingSuffixRows() {
        let store = ConversationStore()
        let sessionID = "sess_prepend_undated_history"
        let beforeLoad = Date()

        store.setHistory([
            CodexHistoryMessage(role: "assistant", content: "现有回答", createdAt: nil)
        ], sessionID: sessionID)
        guard let existing = store.messages(for: sessionID).first else {
            return XCTFail("首屏历史应生成一条消息")
        }
        XCTAssertTrue(existing.isTimestampFallback)
        XCTAssertLessThan(existing.createdAt, beforeLoad.addingTimeInterval(-60), "历史缺时间时不能兜底成当前加载时间")
        XCTAssertFalse(existing.timestampCaptionText.hasPrefix("估 "))

        store.setHistory([
            CodexHistoryMessage(role: "user", content: "更早问题", createdAt: nil),
            CodexHistoryMessage(role: "assistant", content: "现有回答", createdAt: nil)
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        let reused = messages.first { $0.content == "现有回答" }
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(reused?.id, existing.id)
        XCTAssertEqual(reused?.createdAt, existing.createdAt)
        XCTAssertEqual(reused?.isTimestampFallback, true)
        XCTAssertTrue(messages.allSatisfy(\.isTimestampFallback))
        XCTAssertTrue(messages.contains { $0.content == "更早问题" })
    }

    func testConversationStoreTrimsLeastRecentlyUsedSessionCaches() {
        let store = ConversationStore()
        let retainedLimit = ConversationStore.retainedSessionLimit
        let createdAt = Date(timeIntervalSince1970: 300)

        for index in 0..<retainedLimit {
            store.setHistory([
                CodexHistoryMessage(role: "assistant", content: "历史 \(index)", createdAt: createdAt.addingTimeInterval(TimeInterval(index)))
            ], sessionID: "sess_\(index)")
        }
        store.setHistory([
            CodexHistoryMessage(role: "assistant", content: "历史 0", createdAt: createdAt)
        ], sessionID: "sess_0")

        store.setHistory([
            CodexHistoryMessage(role: "assistant", content: "新历史", createdAt: createdAt.addingTimeInterval(TimeInterval(retainedLimit)))
        ], sessionID: "sess_new")

        XCTAssertEqual(store.messagesBySessionID.count, retainedLimit)
        XCTAssertEqual(store.messages(for: "sess_0").first?.content, "历史 0")
        XCTAssertTrue(store.messages(for: "sess_1").isEmpty)
        XCTAssertFalse(store.hasLoadedHistory(sessionID: "sess_1"))
        XCTAssertEqual(store.messages(for: "sess_new").first?.content, "新历史")
    }

    func testConversationStoreLRUTouchKeepsStreamingSessionHotAcrossEvictions() {
        let store = ConversationStore()
        let retainedLimit = ConversationStore.retainedSessionLimit
        let createdAt = Date(timeIntervalSince1970: 350)

        for index in 0..<retainedLimit {
            store.setHistory([
                CodexHistoryMessage(role: "assistant", content: "历史 \(index)", createdAt: createdAt.addingTimeInterval(TimeInterval(index)))
            ], sessionID: "sess_\(index)")
        }

        for index in 0..<5 {
            store.appendSystem("流式片段 \(index)", sessionID: "sess_0")
        }
        store.setHistory([
            CodexHistoryMessage(role: "assistant", content: "新历史 1", createdAt: createdAt.addingTimeInterval(TimeInterval(retainedLimit)))
        ], sessionID: "sess_new_1")
        store.setHistory([
            CodexHistoryMessage(role: "assistant", content: "新历史 2", createdAt: createdAt.addingTimeInterval(TimeInterval(retainedLimit + 1)))
        ], sessionID: "sess_new_2")

        XCTAssertEqual(store.messagesBySessionID.count, retainedLimit)
        XCTAssertTrue(store.messages(for: "sess_0").contains { $0.content == "流式片段 4" })
        XCTAssertTrue(store.messages(for: "sess_1").isEmpty)
        XCTAssertTrue(store.messages(for: "sess_2").isEmpty)
        XCTAssertEqual(store.messages(for: "sess_new_1").first?.content, "新历史 1")
        XCTAssertEqual(store.messages(for: "sess_new_2").first?.content, "新历史 2")
    }

    func testSelectingLoadedSessionRetainsConversationCache() async {
        let conversationStore = ConversationStore()
        let retainedLimit = ConversationStore.retainedSessionLimit
        let createdAt = Date(timeIntervalSince1970: 400)
        let project = makeProject(id: "proj_lru")
        let selectedHistory = makeSession(id: "sess_0", projectID: project.id, title: "已加载历史", status: "history", source: "codex", resumeID: "sess_0")

        for index in 0..<retainedLimit {
            conversationStore.setHistory([
                CodexHistoryMessage(role: "assistant", content: "历史 \(index)", createdAt: createdAt.addingTimeInterval(TimeInterval(index)))
            ], sessionID: "sess_\(index)")
        }
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [selectedHistory]) }
        )

        await store.selectSession(selectedHistory)
        conversationStore.setHistory([
            CodexHistoryMessage(role: "assistant", content: "新历史", createdAt: createdAt.addingTimeInterval(TimeInterval(retainedLimit)))
        ], sessionID: "sess_new")

        XCTAssertEqual(conversationStore.messagesBySessionID.count, retainedLimit)
        XCTAssertEqual(conversationStore.messages(for: selectedHistory.id).first?.content, "历史 0")
        XCTAssertTrue(conversationStore.messages(for: "sess_1").isEmpty)
        XCTAssertEqual(conversationStore.messages(for: "sess_new").first?.content, "新历史")
    }

    func testHistoryMergePreservesRepeatedUnstableMessagesWithSameText() {
        let store = ConversationStore()
        let sessionID = "sess_repeated_unstable_text"

        store.setHistory([
            CodexHistoryMessage(role: "user", content: "继续", createdAt: Date(timeIntervalSince1970: 10)),
            CodexHistoryMessage(role: "user", content: "继续", createdAt: Date(timeIntervalSince1970: 20))
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map(\.content), ["继续", "继续"])
        XCTAssertNotEqual(messages[0].id, messages[1].id)
    }

    func testHistoryEchoMergeRequiresNearbyHistoryTimestamp() {
        let store = ConversationStore()
        let sessionID = "sess_history_echo_window"

        store.appendUser("继续", sessionID: sessionID)
        store.setHistory([
            CodexHistoryMessage(role: "user", content: "继续", createdAt: Date(timeIntervalSince1970: 10))
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.filter { $0.role == .user && $0.content == "继续" }.count, 2)
    }

    func testAgentEventDecodesStructuredAssistantDelta() throws {
        let decoder = JSONDecoder()

        let assistantDelta = try decoder.decode(
            AgentEvent.self,
            from: Data(#"{"type":"assistant_delta","delta":{"text":"结构化增量","role":"assistant","kind":"message"}}"#.utf8)
        )
        if case .assistantDelta(let delta, _) = assistantDelta {
            XCTAssertEqual(delta.text, "结构化增量")
        } else {
            XCTFail("Expected assistant delta event")
        }

        let resolved = try decoder.decode(
            AgentEvent.self,
            from: Data(#"{"type":"approval_resolved","seq":7,"session_id":"sess_output","item_id":"99"}"#.utf8)
        )
        if case .approvalResolved(let meta) = resolved {
            XCTAssertEqual(meta.seq, 7)
            XCTAssertEqual(meta.sessionID, "sess_output")
            XCTAssertEqual(meta.itemID, "99")
        } else {
            XCTFail("Expected approval resolved event")
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

    func testMessageCompletedOverwritesStreamingAssistantDeltaWithSameStableID() throws {
        let store = ConversationStore()
        let sessionID = "sess_completed_overwrites_delta"
        let stableID = "appserver:turn-1:assistant-1"
        let deltaMetadata = AgentEventMetadata(
            seq: 1,
            sessionID: sessionID,
            turnID: "turn-1",
            itemID: "assistant-1",
            messageID: stableID,
            clientMessageID: nil,
            revision: 1,
            createdAt: nil
        )
        store.applyAssistantDelta(
            AgentDelta(text: "Redis 去参加聚会。", role: .assistant, kind: .message),
            metadata: deltaMetadata,
            fallbackSessionID: sessionID
        )

        let completed = try JSONDecoder().decode(
            AgentMessage.self,
            from: Data("""
            {
              "id": "\(stableID)",
              "session_id": "\(sessionID)",
              "turn_id": "turn-1",
              "item_id": "assistant-1",
              "role": "assistant",
              "kind": "message",
              "content": "Redis 去参加聚会。\\n别人问它：你记性好吗？\\nRedis 说：特别好，但得看 TTL。",
              "revision": 2,
              "send_status": "confirmed"
            }
            """.utf8)
        )
        let completedMetadata = AgentEventMetadata(
            seq: 2,
            sessionID: sessionID,
            turnID: "turn-1",
            itemID: "assistant-1",
            messageID: stableID,
            clientMessageID: nil,
            revision: 2,
            createdAt: nil
        )

        store.completeMessage(completed, metadata: completedMetadata, fallbackSessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.stableID, stableID)
        XCTAssertEqual(messages.first?.content, completed.content)
        XCTAssertEqual(messages.first?.sendStatus, .confirmed)
        XCTAssertEqual(store.lastSeenSeq(for: sessionID), 2)
    }

    func testPaginateHistoryWindowsBackwardThroughEarliestMessage() {
        let messages = (0..<5).map { index in
            CodexHistoryMessage(id: "m\(index)", role: "user", content: "msg\(index)", createdAt: nil)
        }

        let latest = CodexAppServerSessionRuntime.paginateHistory(messages, before: nil, limit: 2)
        XCTAssertEqual(latest.messages.map(\.id), ["m3", "m4"])
        XCTAssertEqual(latest.previousCursor, "m3")
        XCTAssertTrue(latest.hasMoreBefore)

        let middle = CodexAppServerSessionRuntime.paginateHistory(messages, before: "m3", limit: 2)
        XCTAssertEqual(middle.messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(middle.previousCursor, "m1")
        XCTAssertTrue(middle.hasMoreBefore)

        // 翻到最早一窗时必须能拿到第一条 m0，并关闭分页入口。
        let earliest = CodexAppServerSessionRuntime.paginateHistory(messages, before: "m1", limit: 2)
        XCTAssertEqual(earliest.messages.map(\.id), ["m0"])
        XCTAssertNil(earliest.previousCursor)
        XCTAssertFalse(earliest.hasMoreBefore)
    }

    func testPaginateHistoryCarriesAuthoritativeTurnItemsAcrossWindowCuts() {
        let turnID = "turn_window_authority"
        let allItemIDs: [AgentItemID] = (20..<25).map { index in "item-\(index)" }
        let messages: [CodexHistoryMessage] = (20..<25).map { index in
            let role = index == 24 ? "assistant" : "system"
            let kind: MessageKind = index == 24 ? .message : .commandSummary
            let itemID: AgentItemID = "item-\(index)"
            return CodexHistoryMessage(
                id: "appserver:\(turnID):\(itemID)",
                role: role,
                kind: kind,
                content: "msg\(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                turnID: turnID,
                itemID: itemID,
                timelineOrdinal: Int64(index)
            )
        }

        let page = CodexAppServerSessionRuntime.paginateHistory(
            messages,
            before: nil,
            limit: 2,
            authoritativeCompletedTurnItems: [
                turnID: Set(allItemIDs)
            ]
        )

        XCTAssertEqual(page.messages.map { $0.itemID }, ["item-23", "item-24"])
        XCTAssertTrue(page.hasMoreBefore)
        XCTAssertEqual(page.authoritativeCompletedTurnItems[turnID], Set(allItemIDs))
    }

    func testPaginateHistoryReturnsAllWhenWithinLimitOrCursorMissing() {
        let messages = (0..<3).map { index in
            CodexHistoryMessage(id: "m\(index)", role: "user", content: "msg\(index)", createdAt: nil)
        }

        let full = CodexAppServerSessionRuntime.paginateHistory(messages, before: nil, limit: 10)
        XCTAssertEqual(full.messages.map(\.id), ["m0", "m1", "m2"])
        XCTAssertNil(full.previousCursor)
        XCTAssertFalse(full.hasMoreBefore)

        let missing = CodexAppServerSessionRuntime.paginateHistory(messages, before: "gone", limit: 2)
        XCTAssertTrue(missing.messages.isEmpty)
        XCTAssertNil(missing.previousCursor)
        XCTAssertFalse(missing.hasMoreBefore)
    }

    func testMessagePageResponseMapsToHistoryMessages() throws {
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
                "send_status": "confirmed",
                "is_timestamp_fallback": true
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
        XCTAssertEqual(response.messages.first?.isTimestampFallback, true)
        XCTAssertEqual(response.nextCursor, "next")
        XCTAssertEqual(response.previousCursor, "prev")
        XCTAssertEqual(response.hasMoreBefore, true)
        XCTAssertEqual(response.snapshotSeq, 9)
        XCTAssertEqual(HistoryMessagesPage(response: response).snapshotSeq, 9)
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

    func testMessagesResponsePreservesCursorAndClientMessageIDFallback() throws {
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
        var messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "Hel")

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
        // 后续 delta 会先进入合并缓冲区，避免每个分片都触发 UI 刷新。
        messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.first?.content, "Hel")

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
        store.markCurrentAssistantCompleted(
            metadata: AgentEventMetadata(
                seq: 3,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_1",
                messageID: nil,
                clientMessageID: nil,
                revision: 3,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .assistant)
        XCTAssertEqual(messages.first?.content, "Hello")
        XCTAssertEqual(messages.first?.stableID, "item_1")
        XCTAssertEqual(messages.first?.sendStatus, .confirmed)
    }

    func testStructuredAssistantDeltaFlushesBufferedTextOnTimer() async throws {
        let store = ConversationStore()
        let sessionID = "sess_delta_timer"

        store.applyAssistantDelta(
            AgentDelta(text: "A", role: .assistant, kind: .message),
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
            AgentDelta(text: "B", role: .assistant, kind: .message),
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
        XCTAssertEqual(store.messages(for: sessionID).first?.content, "A")

        try await Task.sleep(nanoseconds: 160_000_000)

        XCTAssertEqual(store.messages(for: sessionID).first?.content, "AB")
        XCTAssertEqual(store.messages(for: sessionID).first?.revision, 2)
    }

    func testEmptyAssistantDeltaDoesNotCreateBubbleOrReserveRevision() throws {
        let store = ConversationStore()
        let sessionID = "sess_empty_delta"

        store.applyAssistantDelta(
            AgentDelta(text: "", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_empty",
                messageID: nil,
                clientMessageID: nil,
                revision: 2,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        XCTAssertTrue(store.messages(for: sessionID).isEmpty)

        let completed = try JSONDecoder().decode(
            AgentMessage.self,
            from: Data("""
            {
              "id": "item_empty",
              "session_id": "\(sessionID)",
              "role": "assistant",
              "content": "最终回复",
              "revision": 2,
              "send_status": "confirmed"
            }
            """.utf8)
        )

        store.completeMessage(completed, metadata: .empty, fallbackSessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "最终回复")
        XCTAssertEqual(messages.first?.revision, 2)
        XCTAssertEqual(messages.first?.sendStatus, .confirmed)
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

    func testAssistantRevisionCacheIsScopedBySession() {
        let store = ConversationStore()

        store.applyAssistantDelta(
            AgentDelta(text: "A 会话", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: nil,
                sessionID: "sess_a",
                turnID: "turn_a",
                itemID: "item_shared",
                messageID: nil,
                clientMessageID: nil,
                revision: 2,
                createdAt: nil
            ),
            fallbackSessionID: "sess_a"
        )
        store.applyAssistantDelta(
            AgentDelta(text: "B 会话", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: nil,
                sessionID: "sess_b",
                turnID: "turn_b",
                itemID: "item_shared",
                messageID: nil,
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            ),
            fallbackSessionID: "sess_b"
        )

        let first = store.messages(for: "sess_a").first
        let second = store.messages(for: "sess_b").first
        XCTAssertEqual(first?.content, "A 会话")
        XCTAssertEqual(second?.content, "B 会话")
        XCTAssertNotEqual(first?.id, second?.id)
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

    func testAssistantDeltaAppendMaintainsStableMessageIndex() {
        let store = ConversationStore()
        let sessionID = "sess_assistant_index"
        let metadata = AgentEventMetadata(
            seq: nil,
            sessionID: sessionID,
            turnID: "turn_1",
            itemID: "item_1",
            messageID: "msg_assistant_1",
            clientMessageID: nil,
            revision: 1,
            createdAt: nil
        )

        store.applyAssistantDelta(
            AgentDelta(text: "第一段回复", role: .assistant, kind: .message),
            metadata: metadata,
            fallbackSessionID: sessionID
        )
        store.markCurrentAssistantCompleted(metadata: metadata, fallbackSessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.stableID, "msg_assistant_1")
        XCTAssertEqual(messages.first?.sendStatus, .confirmed)
        XCTAssertEqual(messages.first?.content, "第一段回复")
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
              "id": "client:\(clientMessageID)",
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
        XCTAssertEqual(messages.first?.stableID, "client:\(clientMessageID)")
        XCTAssertEqual(messages.first?.content, "帮我跑测试")
        XCTAssertEqual(messages.first?.sendStatus, .confirmed)
        XCTAssertEqual(messages.first?.revision, 1)
        let confirmedMessageID = try XCTUnwrap(messages.first?.id)

        let replay = try JSONDecoder().decode(
            AgentMessage.self,
            from: Data("""
            {
              "id": "client:\(clientMessageID)",
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
        XCTAssertEqual(replayedMessages.first?.stableID, "client:\(clientMessageID)")
        XCTAssertEqual(replayedMessages.first?.revision, 2)
        XCTAssertEqual(replayedMessages.first?.id, confirmedMessageID)

        store.setHistory([
            CodexHistoryMessage(
                id: "client:\(clientMessageID)",
                role: "user",
                content: "帮我跑测试",
                createdAt: Date(timeIntervalSince1970: 2),
                clientMessageID: clientMessageID,
                revision: 2,
                sendStatus: .confirmed
            )
        ], sessionID: sessionID)

        let hydratedMessages = store.messages(for: sessionID)
        XCTAssertEqual(hydratedMessages.count, 1)
        XCTAssertEqual(hydratedMessages.first?.stableID, "client:\(clientMessageID)")
        XCTAssertEqual(hydratedMessages.first?.id, confirmedMessageID)
    }

    func testStructuredEventsDecodeFallbackPayloadsAndApprovalContext() throws {
        let decoder = JSONDecoder()

        let stringDelta = try decoder.decode(
            StructuredAgentEvent.self,
            from: Data(#"{"type":"assistant_delta","data":"字符串增量","seq":8,"session_id":"sess_1","message_id":"msg_1"}"#.utf8)
        )
        if case .assistantDelta(let delta, let meta) = stringDelta {
            XCTAssertEqual(delta.text, "字符串增量")
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

        let resolved = try decoder.decode(
            StructuredAgentEvent.self,
            from: Data(#"{"type":"approval_resolved","seq":10,"session_id":"sess_1","item_id":"approval_1"}"#.utf8)
        )
        if case .approvalResolved(let meta) = resolved {
            XCTAssertEqual(meta.seq, 10)
            XCTAssertEqual(meta.sessionID, "sess_1")
            XCTAssertEqual(meta.itemID, "approval_1")
        } else {
            XCTFail("Expected approval resolved")
        }
    }

    func testAgentSessionDecodesStableServerIdentifiers() throws {
        let json = """
        {
          "id": "sess_1",
          "project_id": "proj_1",
          "project": "Mimi Remote",
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

    func testRecentWorkspaceStoreScopesByEndpointAndSupportsForget() {
        let first = AgentWorkspace(id: "proj_a", name: "Project A", path: "/tmp/proj-a")
        let second = AgentWorkspace(id: "proj_b", name: "Project B", path: "/tmp/proj-b")
        let store = makeRecentWorkspaceStore(workspaces: [], endpoint: "http://mac-a.local:8787")

        _ = store.upsert(first, endpoint: "http://mac-a.local:8787", openedAt: Date(timeIntervalSince1970: 10))
        _ = store.upsert(second, endpoint: "http://mac-b.local:8787", openedAt: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(store.load(endpoint: "http://mac-a.local:8787").map(\.id), [first.id])
        XCTAssertEqual(store.load(endpoint: "http://mac-b.local:8787").map(\.id), [second.id])

        _ = store.forget(id: first.id, endpoint: "http://mac-a.local:8787")

        XCTAssertTrue(store.load(endpoint: "http://mac-a.local:8787").isEmpty)
        XCTAssertEqual(store.load(endpoint: "http://mac-b.local:8787").map(\.id), [second.id])
    }

    func testSessionListPreferenceStoreScopesByEndpoint() {
        let store = makeSessionListPreferenceStore()
        store.save(
            SessionListPreferences(pinnedSessionIDs: ["session_a"], archivedSessionIDs: ["session_b"]),
            endpoint: "http://agent-a.local:8787"
        )
        store.save(
            SessionListPreferences(pinnedSessionIDs: ["session_c"], archivedSessionIDs: []),
            endpoint: "http://agent-b.local:8787"
        )

        XCTAssertEqual(store.load(endpoint: "http://agent-a.local:8787").pinnedSessionIDs, ["session_a"])
        XCTAssertEqual(store.load(endpoint: "http://agent-a.local:8787").archivedSessionIDs, ["session_b"])
        XCTAssertEqual(store.load(endpoint: "http://agent-b.local:8787").pinnedSessionIDs, ["session_c"])
        XCTAssertTrue(store.load(endpoint: "http://agent-b.local:8787").archivedSessionIDs.isEmpty)
    }

    func testSessionReminderStoreScopesByEndpoint() {
        let store = makeSessionReminderStore()
        let first = SessionReminder(
            sessionID: "session_a",
            title: "回看 A",
            fireAt: Date(timeIntervalSince1970: 3_600),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = SessionReminder(
            sessionID: "session_b",
            title: "回看 B",
            fireAt: Date(timeIntervalSince1970: 7_200),
            createdAt: Date(timeIntervalSince1970: 2)
        )

        store.save([first.sessionID: first], endpoint: "http://agent-a.local:8787")
        store.save([second.sessionID: second], endpoint: "http://agent-b.local:8787")

        XCTAssertEqual(store.load(endpoint: "http://agent-a.local:8787"), [first.sessionID: first])
        XCTAssertEqual(store.load(endpoint: "http://agent-b.local:8787"), [second.sessionID: second])
    }

    func testRefreshWithoutRecentWorkspacesDoesNotLoadSessions() async {
        let project = makeProject(id: "proj_no_recent")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = MockSessionStoreClient(projects: [project], sessions: [history])
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)

        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertTrue(store.sidebarProjects.isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(client.requestedProjectIDs.isEmpty)
    }

    func testWorkspaceRecentMapsRootProjectSessionsToWorkspaceID() async {
        let rootProject = makeProject(id: "proj_root")
        let workspace = AgentWorkspace(
            id: "ws_child",
            name: "ios",
            path: "/tmp/\(rootProject.id)/ios",
            rootProjectID: rootProject.id,
            rootProjectName: rootProject.name,
            rootProjectPath: rootProject.path,
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        )
        let childSession = AgentSession(
            id: "codex_child",
            projectID: rootProject.id,
            project: rootProject.name,
            dir: workspace.path,
            title: "子目录会话",
            status: "history",
            source: "codex",
            resumeID: "child",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            projectPages: [
                rootProject.id: SessionsPage(sessions: [childSession])
            ]
        )
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [workspace], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        store.selectedProjectID = workspace.id
        await store.refreshAll(autoAttach: false)

        XCTAssertEqual(client.requestedProjectIDs, [rootProject.id])
        XCTAssertEqual(store.sidebarProjects.map(\.id), [workspace.id])
        XCTAssertEqual(store.sessions(forProjectID: workspace.id).map(\.id), [childSession.id])
        XCTAssertEqual(store.sessions.first?.projectID, workspace.id)
    }

    func testOpenWorkspaceStoresResolvedPathOutsideCandidateList() async {
        let rootProject = makeProject(id: "proj_root")
        let workspace = AgentWorkspace(
            id: "ws_deep_child",
            name: "ios",
            path: "\(rootProject.path)/apps/mobile/ios",
            rootProjectID: rootProject.id,
            rootProjectName: rootProject.name,
            rootProjectPath: rootProject.path
        )
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            projectPages: [
                rootProject.id: SessionsPage(sessions: [])
            ],
            resolveResults: [
                workspace.path: .success(workspace)
            ]
        )
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        let opened = await store.openWorkspace(path: "  \(workspace.path)  ")

        XCTAssertTrue(opened)
        XCTAssertEqual(client.requestedResolvePaths, [workspace.path])
        XCTAssertEqual(client.requestedWorkspaceIDs, [workspace.id])
        XCTAssertEqual(client.requestedProjectIDs, [rootProject.id])
        XCTAssertEqual(store.selectedProjectID, workspace.id)
        XCTAssertEqual(store.sidebarProjects.map(\.id), [workspace.id])
        XCTAssertNil(store.errorMessage)
    }

    func testDirectoryListResponseDecodesAgentdPayload() throws {
        let json = """
        {
          "path": "/Users/me",
          "parent_path": null,
          "entries": [
            {"name": "finance", "path": "/Users/me/finance", "is_dir": true, "can_open": true, "can_browse": true}
          ]
        }
        """
        let response = try JSONDecoder().decode(DirectoryListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.path, "/Users/me")
        XCTAssertNil(response.parentPath)
        XCTAssertEqual(response.entries.map(\.name), ["finance"])
        XCTAssertEqual(response.entries.first?.path, "/Users/me/finance")
        XCTAssertEqual(response.entries.first?.canOpen, true)
        XCTAssertEqual(response.entries.first?.canBrowse, true)
        XCTAssertNil(response.truncated)
    }

    func testListDirectoriesUsesInjectedClientAndKeepsErrorsLocal() async throws {
        let rootProject = makeProject(id: "proj_root")
        let listing = DirectoryListResponse(
            path: rootProject.path,
            parentPath: nil,
            entries: [
                DirectoryEntry(name: "finance", path: "\(rootProject.path)/finance", isDir: true, canOpen: true, canBrowse: true)
            ],
            truncated: nil
        )
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            directoryListResults: [
                "": .success(listing),
                "/forbidden": .failure(AgentAPIError.server(status: 403, message: "路径不在允许范围内或不可访问"))
            ]
        )
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        let response = try await store.listDirectories(path: "")
        XCTAssertEqual(response, listing)

        do {
            _ = try await store.listDirectories(path: "/forbidden")
            XCTFail("allowlist 外目录应抛错")
        } catch {
            // 浏览错误应抛给调用方内联展示，不污染全局 errorMessage。
        }
        XCTAssertEqual(client.requestedDirectoryPaths, ["", "/forbidden"])
        XCTAssertNil(store.errorMessage)
    }

    func testSessionStorePinsAndArchivesSessionsLocally() async {
        let project = makeProject(id: "proj_prefs")
        let older = makeSession(
            id: "session_older",
            projectID: project.id,
            title: "旧会话",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = makeSession(
            id: "session_newer",
            projectID: project.id,
            title: "新会话",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectPages: [
                project.id: SessionsPage(sessions: [older, newer])
            ],
            sessionArchiveResults: [
                older.id: .success(())
            ]
        )
        let appStore = AppStore()
        let preferences = makeSessionListPreferenceStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [AgentWorkspace(project: project)], endpoint: appStore.endpoint),
            sessionListPreferenceStore: preferences,
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [newer.id, older.id])

        store.toggleSessionPinned(older)
        XCTAssertTrue(store.isSessionPinned(older.id))
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [older.id, newer.id])
        XCTAssertEqual(preferences.load(endpoint: appStore.endpoint).pinnedSessionIDs, [older.id])

        await store.toggleSessionArchivedRemote(older)
        XCTAssertFalse(store.isSessionPinned(older.id))
        XCTAssertTrue(store.isSessionArchived(older.id))
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [newer.id])
        XCTAssertEqual(preferences.load(endpoint: appStore.endpoint).archivedSessionIDs, [older.id])

        await store.toggleSessionArchivedRemote(older)
        XCTAssertFalse(store.isSessionArchived(older.id))
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [newer.id, older.id])
        XCTAssertEqual(client.requestedSessionArchives, [
            RequestedSessionArchive(id: older.id, archived: true),
            RequestedSessionArchive(id: older.id, archived: false)
        ])
    }

    func testSessionStoreSchedulesAndClearsLocalReminder() async throws {
        let project = makeProject(id: "proj_reminder")
        let session = makeSession(
            id: "session_reminder",
            projectID: project.id,
            title: "检查结果",
            status: "history",
            source: "codex"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectPages: [
                project.id: SessionsPage(sessions: [session])
            ]
        )
        let appStore = AppStore()
        let reminderStore = makeSessionReminderStore()
        let scheduler = FakeSessionReminderScheduler()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [AgentWorkspace(project: project)], endpoint: appStore.endpoint),
            sessionReminderStore: reminderStore,
            sessionReminderScheduler: scheduler,
            clientFactory: { client }
        )
        let now = Date(timeIntervalSince1970: 1_000)

        await store.refreshAll(autoAttach: false)
        await store.scheduleSessionReminder(session, after: 30 * 60, now: now)

        let reminder = try XCTUnwrap(store.sessionReminder(for: session.id))
        XCTAssertEqual(reminder.sessionID, session.id)
        XCTAssertEqual(reminder.title, session.title)
        XCTAssertEqual(reminder.fireAt, now.addingTimeInterval(30 * 60))
        XCTAssertEqual(scheduler.scheduled, [reminder])
        XCTAssertEqual(reminderStore.load(endpoint: appStore.endpoint)[session.id], reminder)

        store.clearSessionReminder(session)

        XCTAssertNil(store.sessionReminder(for: session.id))
        XCTAssertEqual(scheduler.canceledSessionIDs, [session.id])
        XCTAssertTrue(reminderStore.load(endpoint: appStore.endpoint).isEmpty)
    }

    func testPreviewFileWritesDecodedPayloadToTemporaryFile() async throws {
        let filePath = "/repo/report.pdf"
        let payload = Data("preview-payload".utf8)
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            fileReadResults: [
                filePath: .success(FileReadResponse(
                    path: filePath,
                    name: "../report.pdf",
                    contentType: "application/pdf",
                    size: Int64(payload.count),
                    contentBase64: payload.base64EncodedString()
                ))
            ]
        )
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        let url = try await store.previewFile(path: filePath)
        XCTAssertEqual(client.requestedFileReadPaths, [filePath])
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-report.pdf"))
        XCTAssertNil(store.errorMessage)
    }

    func testPreviewHistoryMediaWritesDecodedPayloadToTemporaryFile() async throws {
        let mediaID = "media-123"
        let payload = Data("history-image-payload".utf8)
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            historyMediaResults: [
                mediaID: .success(FileReadResponse(
                    path: "agentd-history-media://\(mediaID)",
                    name: "history-image.png",
                    contentType: "image/png",
                    size: Int64(payload.count),
                    contentBase64: payload.base64EncodedString()
                ))
            ]
        )
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        let url = try await store.previewHistoryMedia(id: mediaID)
        XCTAssertEqual(client.requestedHistoryMediaIDs, [mediaID])
        XCTAssertEqual(client.requestedFileReadPaths, [])
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-history-image.png"))
        XCTAssertNil(store.errorMessage)
    }

    func testWorkspaceLoadFailureMarksUnavailableWhenResolveRejects() async {
        let rootProject = makeProject(id: "proj_root")
        let workspace = makeChildWorkspace(id: "ws_gone", name: "gone", root: rootProject)
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            workspaceSessionsError: [workspace.id: AgentAPIError.server(status: 403, message: "cwd 必须来自 projects allowlist")],
            resolveResults: [workspace.path: .failure(AgentAPIError.server(status: 403, message: "路径不在允许范围内或不可访问"))]
        )
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [workspace], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        store.selectedProjectID = workspace.id
        await store.refreshAll(autoAttach: false)

        // 会话加载失败 + resolve 明确 4xx → 单独标记该工作区不可用，且不冒泡成全局错误。
        XCTAssertTrue(store.isWorkspaceUnavailable(workspace.id))
        XCTAssertEqual(client.requestedResolvePaths, [workspace.path])
        XCTAssertNil(store.errorMessage)
    }

    func testWorkspaceLoadFailureStaysTransientWhenResolveSucceeds() async {
        let rootProject = makeProject(id: "proj_root")
        let workspace = makeChildWorkspace(id: "ws_flaky", name: "flaky", root: rootProject)
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            workspaceSessionsError: [workspace.id: AgentAPIError.server(status: 502, message: "连接 app-server gateway 上游失败")],
            resolveResults: [workspace.path: .success(workspace)]
        )
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [workspace], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        store.selectedProjectID = workspace.id
        await store.refreshAll(autoAttach: false)

        // resolve 仍成功 → 判定为瞬时故障：不标记不可用，仍按普通错误处理以便重试。
        XCTAssertFalse(store.isWorkspaceUnavailable(workspace.id))
        XCTAssertEqual(client.requestedResolvePaths, [workspace.path])
        XCTAssertNotNil(store.errorMessage)
    }

    func testForgetWorkspaceClearsUnavailableMark() async {
        let rootProject = makeProject(id: "proj_root")
        let workspace = makeChildWorkspace(id: "ws_gone", name: "gone", root: rootProject)
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            workspaceSessionsError: [workspace.id: AgentAPIError.server(status: 403, message: "denied")],
            resolveResults: [workspace.path: .failure(AgentAPIError.server(status: 403, message: "denied"))]
        )
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [workspace], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        store.selectedProjectID = workspace.id
        await store.refreshAll(autoAttach: false)
        XCTAssertTrue(store.isWorkspaceUnavailable(workspace.id))

        store.forgetWorkspace(workspace.project)

        XCTAssertFalse(store.isWorkspaceUnavailable(workspace.id))
        XCTAssertTrue(store.sidebarProjects.isEmpty)
    }

    func testSessionStoreAutoAttachKeepsExplicitHistorySelection() async {
        let project = makeProject(id: "proj_1")
        let selectedHistory = makeSession(id: "codex_selected", projectID: project.id, title: "用户点选的历史", status: "history", source: "codex", resumeID: "selected")
        let latestRunning = makeSession(id: "sess_latest", projectID: project.id, title: "最新运行会话", status: "running", source: "codex")
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

        XCTAssertEqual(client.requestedProjectIDs.compactMap { $0 }, [project.id])
        XCTAssertEqual(store.selectedSessionID, selectedHistory.id)
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertTrue(conversationStore.hasLoadedHistory(sessionID: selectedHistory.id))
    }

    func testSessionStoreAutoAttachSelectsRunningSessionWhenNothingSelected() async throws {
        let project = makeProject(id: "proj_auto_attach")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史会话", status: "history", source: "codex", resumeID: "history")
        let running = makeSession(id: "sess_auto_running", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let client = MockSessionStoreClient(projects: [project], sessions: [history, running])
        var sockets: [MockWebSocketClient] = []
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project, lastOpenedAt: Date(timeIntervalSince1970: 10))],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: true)

        XCTAssertEqual(store.selectedSessionID, running.id)
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertTrue(store.isSelectedSessionObserving)
        XCTAssertTrue(sockets.isEmpty)
        XCTAssertEqual(store.webSocketStatus, .disconnected)
    }

    func testSelectingRunningSessionRefreshesHistoryAndSuppressesBufferedMessageReplay() async throws {
        let project = makeProject(id: "proj_live_resume")
        let running = makeSession(id: "sess_live_resume", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let refreshedHistory = [
            CodexHistoryMessage(
                id: "live-user",
                role: "user",
                content: "开始长任务",
                createdAt: Date(timeIntervalSince1970: 10)
            ),
            CodexHistoryMessage(
                id: "live-assistant",
                role: "assistant",
                content: "离开期间已经完成的最新回答",
                createdAt: Date(timeIntervalSince1970: 20),
                updatedAt: Date(timeIntervalSince1970: 30),
                turnID: "turn-live",
                itemID: "assistant-live",
                sendStatus: .confirmed
            )
        ]
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            historyPages: [running.id: HistoryMessagesPage(messages: refreshedHistory)]
        )
        let conversationStore = ConversationStore()
        conversationStore.setHistory([
            CodexHistoryMessage(
                id: "stale-assistant",
                role: "assistant",
                content: "旧回答",
                createdAt: Date(timeIntervalSince1970: 1)
            )
        ], sessionID: running.id)
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.takeOverSession(running)
        await store.selectSession(running)

        XCTAssertEqual(client.requestedMessageSessionIDs, [running.id])
        XCTAssertEqual(client.requestedMessageCursors, [nil])
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(sockets[0].replayBufferedEventsByConnect, [false])
        XCTAssertEqual(conversationStore.messages(for: running.id).suffix(refreshedHistory.count).map(\.content), refreshedHistory.map(\.content))
    }

    func testSessionStoreSendsUserInputAnswersThroughExistingSocket() async throws {
        let project = makeProject(id: "proj_user_input")
        let request = AgentUserInputRequest(
            id: "input-1",
            threadID: "sess_user_input",
            turnID: "turn-1",
            itemID: "input-1",
            questions: [
                AgentUserInputQuestion(
                    id: "scope",
                    header: "范围",
                    question: "先做哪一部分？",
                    isOther: true,
                    isSecret: false,
                    options: [AgentUserInputOption(label: "后端", description: "先落 API")]
                )
            ]
        )
        let running = AgentSession(
            id: request.threadID,
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: "等待引导",
            status: "waiting_for_input",
            source: "codex",
            resumeID: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            pendingUserInput: request
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        let conversationStore = ConversationStore()
        conversationStore.appendSystem("等待补充信息：\(request.title)", sessionID: running.id, kind: .userInput)
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        for _ in 0..<50 where sockets.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(sockets.count, 1)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        store.respondToUserInput(request, answers: ["scope": ["后端", "只做最小闭环"]])

        XCTAssertEqual(sockets[0].sentUserInputResponses.count, 1)
        XCTAssertEqual(sockets[0].sentUserInputResponses.first?.requestID, "input-1")
        XCTAssertEqual(sockets[0].sentUserInputResponses.first?.answers["scope"], ["后端", "只做最小闭环"])
        XCTAssertTrue(store.isUserInputResponsePending(request))
        XCTAssertEqual(store.selectedSession?.status, "running")
        XCTAssertNil(store.selectedSession?.pendingUserInput)
        XCTAssertEqual(conversationStore.messages(for: running.id).last?.content, "补充信息已提交：范围")

        await store.refreshAll(autoAttach: false)

        XCTAssertEqual(store.selectedSession?.status, "running")
        XCTAssertNil(store.selectedSession?.pendingUserInput)

        sockets[0].onUserInputResponseFailure?("input-1", "request expired")
        try await waitForSelectedSessionStatus("waiting_for_input", store: store)

        XCTAssertEqual(store.selectedSession?.pendingUserInput, request)
        XCTAssertFalse(store.isUserInputResponsePending(request))
        XCTAssertEqual(conversationStore.messages(for: running.id).last?.content, "等待补充信息：范围")
    }

    func testSessionStoreReturnToListDoesNotPublishWhenAlreadyCleared() {
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        var publishCount = 0
        var cancellables: Set<AnyCancellable> = []

        store.objectWillChange
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        // 已经处于会话列表页时再次返回，不应重复写入 nil/disconnected 状态刷新整棵侧栏 UI。
        store.returnToSessionList()

        XCTAssertEqual(publishCount, 0)
    }

    func testSelectingAlreadySelectedHistoryDoesNotPublishWhenHistoryLoaded() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let conversationStore = ConversationStore()
        conversationStore.setHistory([
            CodexHistoryMessage(id: "rollout:1", role: "assistant", content: "已加载", createdAt: Date(timeIntervalSince1970: 1))
        ], sessionID: history.id)
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [history]) },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )
        store.selectedProjectID = project.id
        store.selectedSessionID = history.id
        await store.toggleProjectExpansion(project)
        // 历史会话的稳态现在包含事件订阅：先完整选择一次并让 socket 连上，
        // 再排空静默补拉任务，进入稳态后重复点选才是 no-op。
        await store.selectSession(history)
        sockets.last?.emitStatus(.connected)
        for _ in 0..<10 {
            await Task.yield()
        }
        var publishCount = 0
        var cancellables: Set<AnyCancellable> = []

        store.objectWillChange
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        // Codex/litter 都避免 no-op diff 继续下发事件；重复点当前历史行也不应刷新侧栏。
        await store.selectSession(history)

        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertEqual(store.selectedSessionID, history.id)
        XCTAssertEqual(sockets.count, 1)
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

    func testSelectingHistorySessionKeepsSelectionWhenNoRolloutFound() async {
        let project = makeProject(id: "proj_no_rollout")
        let history = makeSession(
            id: "codex_no_rollout",
            projectID: project.id,
            title: "缺失 rollout",
            status: "history",
            source: "codex",
            resumeID: "missing-rollout"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            messagesError: AgentAPIError.server(status: 404, message: "no rollout found")
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
        // 历史读取失败只影响历史面板，不应把会话选择清掉或伪装成仍在运行的 turn。
        XCTAssertTrue(store.statusMessage?.contains("no rollout found") == true)
        XCTAssertNil(store.selectedForegroundActivity)
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

    func testWorkspaceCatalogRefreshDoesNotChangeActiveSessionContext() async throws {
        let project = makeProject(id: "proj_catalog_refresh")
        let session = makeSession(
            id: "sess_catalog_refresh",
            projectID: project.id,
            title: "正在查看的会话",
            status: "history",
            source: "codex",
            resumeID: "catalog-refresh"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            messagesResult: []
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectProject(project)
        await store.selectSession(session)
        let selectedProjectID = store.selectedProjectID
        let selectedSessionID = store.selectedSessionID
        let socketCount = sockets.count

        try await store.refreshWorkspaceCatalog()

        XCTAssertEqual(store.selectedProjectID, selectedProjectID)
        XCTAssertEqual(store.selectedSessionID, selectedSessionID)
        XCTAssertEqual(sockets.count, socketCount)
        XCTAssertEqual(store.sidebarProjects.map(\.id), [project.id])
    }

    func testApprovalSummaryDecodesLegacyPayloadAndRequiresDetailsForApproval() throws {
        let legacyJSON = #"{"id":"approval-legacy","title":"运行命令","kind":"command","count":1}"#
        let legacy = try JSONDecoder().decode(ApprovalSummary.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(legacy.body)
        XCTAssertNil(legacy.risk)
        XCTAssertFalse(legacy.hasDecisionContext)

        let explicit = ApprovalSummary(
            id: "approval-explicit",
            title: "运行 go test ./...",
            body: "go test ./...",
            kind: "command",
            risk: "会执行测试命令",
            count: 1
        )
        XCTAssertTrue(explicit.hasDecisionContext)
    }

    func testEventReducerRetainsApprovalBodyAndRisk() async throws {
        let reducer = EventReducer()
        let output = await reducer.reduce(
            .approvalRequest(
                AgentApprovalRequest(
                    id: "approval-detail",
                    title: "运行 go test ./...",
                    body: "go test ./...",
                    kind: "command",
                    risk: "将在当前工作区执行"
                ),
                AgentEventMetadata(
                    seq: 1,
                    sessionID: "sess-approval-detail",
                    turnID: "turn-1",
                    itemID: "item-1",
                    messageID: nil,
                    clientMessageID: nil,
                    revision: nil,
                    createdAt: nil
                )
            ),
            fallbackSessionID: "fallback",
            outputIdleClearDelay: 0
        )

        let approval = try XCTUnwrap(output.pendingApprovalUpdates.first?.1)
        XCTAssertEqual(approval.body, "go test ./...")
        XCTAssertEqual(approval.risk, "将在当前工作区执行")
    }

    func testSessionStoreSearchFiltersLoadedSessionsAndProjects() async {
        let firstProject = makeProject(id: "proj_alpha")
        let secondProject = makeProject(id: "proj_beta")
        let metadataReview = makeSession(
            id: "codex_review",
            projectID: firstProject.id,
            title: "审核元数据修复",
            status: "history",
            source: "codex",
            resumeID: "review",
            preview: "替换 App Store 高风险描述"
        )
        let featureAudit = makeSession(
            id: "codex_feature_audit",
            projectID: secondProject.id,
            title: "功能对齐检查",
            status: "history",
            source: "codex",
            resumeID: "feature"
        )
        let client = MockSessionStoreClient(
            projects: [firstProject, secondProject],
            sessions: [],
            projectSessions: [
                firstProject.id: [metadataReview],
                secondProject.id: [featureAudit]
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.selectProject(firstProject)
        await store.selectProject(secondProject)

        store.selectedProjectID = firstProject.id
        store.sessionSearchQuery = "App Store"
        XCTAssertEqual(store.filteredSessions.map(\.id), [metadataReview.id])
        XCTAssertEqual(store.filteredSidebarProjects.map(\.id), [firstProject.id])
        XCTAssertEqual(store.sessionListSnapshot(forProjectID: firstProject.id).visibleSessions.map(\.id), [metadataReview.id])

        store.sessionSearchQuery = "proj_beta"
        XCTAssertEqual(store.filteredSidebarProjects.map(\.id), [secondProject.id])

        store.sessionSearchQuery = ""
        XCTAssertEqual(store.filteredSessions.map(\.id), [metadataReview.id])
        XCTAssertEqual(Set(store.filteredSidebarProjects.map(\.id)), Set([firstProject.id, secondProject.id]))
    }

    func testSessionStoreRefreshesGitStatusForSelectedSessionPath() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git", projectID: project.id, title: "检查 Git", status: "history", source: "codex", resumeID: "git")
        let gitStatus = GitStatusResponse(
            path: session.dir,
            isRepository: true,
            branch: "main",
            head: "abc123",
            statusText: " M README.md",
            diffStat: " README.md | 2 +-",
            unstagedDiff: "@@ -1 +1 @@\n-before\n+after",
            stagedDiff: nil,
            truncated: false,
            truncatedNote: nil
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitStatusResults: [session.dir: .success(gitStatus)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.refreshSelectedGitStatus()

        XCTAssertEqual(client.requestedGitStatusPaths, [session.dir])
        XCTAssertEqual(store.selectedGitStatus?.unstagedDiff, gitStatus.unstagedDiff)
        XCTAssertNil(store.selectedGitStatusErrorMessage)
    }

    func testSessionStorePerformsGitActionAndUpdatesCachedStatus() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_action", projectID: project.id, title: "暂存 Git", status: "history", source: "codex", resumeID: "git-action")
        let updatedStatus = GitStatusResponse(
            path: session.dir,
            isRepository: true,
            branch: "main",
            head: "abc123",
            statusText: "M  README.md",
            diffStat: nil,
            unstagedDiff: nil,
            stagedDiff: "@@ -1 +1 @@\n-before\n+after",
            files: [
                GitFileStatus(path: "README.md", code: "M ", staged: true, unstaged: false, untracked: false)
            ],
            truncated: false,
            truncatedNote: nil
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitActionResults: [session.dir: .success(updatedStatus)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.performSelectedGitAction(.stage, files: ["README.md"])

        XCTAssertEqual(client.requestedGitActions, [
            RequestedGitAction(path: session.dir, action: .stage, files: ["README.md"])
        ])
        XCTAssertEqual(store.selectedGitStatus?.stagedDiff, updatedStatus.stagedDiff)
        XCTAssertEqual(store.selectedGitStatus?.files.first?.path, "README.md")
        XCTAssertNil(store.selectedGitActionErrorMessage)
    }

    func testSessionStorePerformsGitPatchActionAndUpdatesCachedStatus() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_patch_action", projectID: project.id, title: "暂存 hunk", status: "history", source: "codex", resumeID: "git-patch-action")
        let patch = "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-before\n+after\n"
        let updatedStatus = GitStatusResponse(
            path: session.dir,
            isRepository: true,
            branch: "main",
            head: "abc123",
            statusText: "M  README.md",
            diffStat: nil,
            unstagedDiff: nil,
            stagedDiff: patch,
            files: [
                GitFileStatus(path: "README.md", code: "M ", staged: true, unstaged: false, untracked: false)
            ],
            truncated: false,
            truncatedNote: nil
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitPatchActionResults: [session.dir: .success(updatedStatus)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.performSelectedGitPatchAction(.stagePatch, patch: patch)

        XCTAssertEqual(client.requestedGitPatchActions, [
            RequestedGitPatchAction(path: session.dir, action: .stagePatch, patch: patch.trimmingCharacters(in: .whitespacesAndNewlines))
        ])
        XCTAssertEqual(store.selectedGitStatus?.stagedDiff, updatedStatus.stagedDiff)
        XCTAssertNil(store.selectedGitActionErrorMessage)
    }

    func testSessionStoreCommitsGitChangesAndUpdatesCachedStatus() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_commit", projectID: project.id, title: "提交 Git", status: "history", source: "codex", resumeID: "git-commit")
        let cleanStatus = GitStatusResponse(
            path: session.dir,
            isRepository: true,
            branch: "main",
            head: "def456",
            statusText: nil,
            diffStat: nil,
            unstagedDiff: nil,
            stagedDiff: nil,
            files: [],
            truncated: false,
            truncatedNote: nil
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitCommitResults: [session.dir: .success(cleanStatus)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.commitSelectedGitChanges(message: " update readme ")

        XCTAssertEqual(client.requestedGitCommits, [
            RequestedGitCommit(path: session.dir, message: "update readme")
        ])
        XCTAssertEqual(store.selectedGitStatus?.head, "def456")
        XCTAssertEqual(store.selectedGitStatus?.hasChanges, false)
        XCTAssertNil(store.selectedGitActionErrorMessage)
    }

    func testSessionStorePushesGitBranchAndUpdatesStatus() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_push", projectID: project.id, title: "Push Git", status: "history", source: "codex", resumeID: "git-push")
        let status = GitStatusResponse(
            path: session.dir,
            isRepository: true,
            branch: "mimi/feature",
            head: "fed456",
            statusText: nil,
            diffStat: nil,
            unstagedDiff: nil,
            stagedDiff: nil,
            files: [],
            truncated: false,
            truncatedNote: nil
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitPushResults: [
                session.dir: .success(GitPushResponse(path: session.dir, remote: "origin", branch: "mimi/feature", output: "pushed", status: status))
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.pushSelectedGitBranch(remote: " origin ")

        XCTAssertEqual(client.requestedGitPushes, [
            RequestedGitPush(path: session.dir, remote: "origin")
        ])
        XCTAssertEqual(store.selectedGitStatus?.head, "fed456")
        XCTAssertNil(store.selectedGitActionErrorMessage)
    }

    func testSessionStoreCreatesDraftPullRequestAndStoresURL() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_pr", projectID: project.id, title: "PR Git", status: "history", source: "codex", resumeID: "git-pr")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitPullRequestResults: [
                session.dir: .success(GitPullRequestResponse(
                    path: session.dir,
                    branch: "mimi/feature",
                    url: "https://github.com/example/repo/pull/1",
                    output: "https://github.com/example/repo/pull/1"
                ))
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.createSelectedPullRequest(title: " Draft PR ", body: "Summary", draft: true)

        XCTAssertEqual(client.requestedGitPullRequests, [
            RequestedGitPullRequest(path: session.dir, title: "Draft PR", body: "Summary", draft: true)
        ])
        XCTAssertEqual(store.selectedPullRequestURL, "https://github.com/example/repo/pull/1")
        XCTAssertEqual(store.selectedPullRequestStatus?.branch, "mimi/feature")
        XCTAssertEqual(store.selectedPullRequestStatus?.title, "Draft PR")
        XCTAssertEqual(store.selectedPullRequestStatus?.isDraft, true)
        XCTAssertNil(store.selectedGitActionErrorMessage)
    }

    func testSessionStoreRefreshesPullRequestStatus() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_pr_status", projectID: project.id, title: "PR 状态", status: "history", source: "codex", resumeID: "git-pr-status")
        let status = GitPullRequestStatusResponse(
            path: session.dir,
            branch: "mimi/feature",
            exists: true,
            number: 42,
            title: "Review changes",
            state: "OPEN",
            url: "https://github.com/example/repo/pull/42",
            isDraft: false,
            reviewDecision: "REVIEW_REQUIRED",
            mergeStateStatus: "CLEAN",
            headRefName: "mimi/feature",
            baseRefName: "main"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitPullRequestStatusResults: [session.dir: .success(status)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.refreshSelectedPullRequestStatus()

        XCTAssertEqual(client.requestedGitPullRequestStatusPaths, [session.dir])
        XCTAssertEqual(store.selectedPullRequestStatus, status)
        XCTAssertEqual(store.selectedPullRequestURL, status.url)
        XCTAssertNil(store.selectedPullRequestStatusErrorMessage)
    }

    func testCommandActionDecodesConfirmationFlagWithSafeDefault() throws {
        let json = """
        {
          "path": "/Users/me/code/app",
          "actions": [
            {
              "id": "go-test",
              "name": "Go Test",
              "command": "go",
              "args": ["test", "./..."],
              "working_dir": "/Users/me/code/app",
              "timeout_seconds": 60
            },
            {
              "id": "clean-cache",
              "name": "Clean Cache",
              "command": "go",
              "args": ["clean", "-cache"],
              "working_dir": "/Users/me/code/app",
              "timeout_seconds": 30,
              "requires_confirmation": true
            }
          ]
        }
        """

        let response = try AgentAPIClient.decoder.decode(CommandActionListResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.actions.map(\.id), ["go-test", "clean-cache"])
        XCTAssertFalse(response.actions[0].requiresConfirmation)
        XCTAssertTrue(response.actions[1].requiresConfirmation)
    }

    func testSessionStoreLoadsAndRunsCommandActions() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_action", projectID: project.id, title: "运行动作", status: "history", source: "codex", resumeID: "action")
        let action = AgentCommandAction(
            id: "go-test",
            name: "Go Test",
            command: "go",
            args: ["test", "./..."],
            workingDir: session.dir,
            timeoutSeconds: 20,
            requiresConfirmation: true
        )
        let result = CommandActionRunResponse(
            id: action.id,
            name: action.name,
            path: session.dir,
            workingDir: session.dir,
            command: action.command,
            args: action.args,
            success: true,
            exitCode: 0,
            output: "ok",
            truncated: false,
            timedOut: false,
            durationMS: 42
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            commandActionResults: [session.dir: .success([action])],
            commandActionRunResults: ["\(session.dir)#\(action.id)": .success(result)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.refreshSelectedCommandActions()
        await store.runSelectedCommandAction(action)

        XCTAssertEqual(client.requestedCommandActionPaths, [session.dir])
        XCTAssertEqual(client.requestedCommandActionRuns, [RequestedCommandActionRun(path: session.dir, id: action.id, confirmed: true)])
        XCTAssertEqual(store.selectedCommandActions, [action])
        XCTAssertEqual(store.selectedCommandActionResult, result)
        XCTAssertEqual(store.selectedCommandActionHistory, [result])
        XCTAssertNil(store.selectedCommandActionErrorMessage)
    }

    func testSessionStoreQueuesCommandActionsFIFO() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_action_queue", projectID: project.id, title: "动作队列", status: "history", source: "codex", resumeID: "action-queue")
        let firstAction = AgentCommandAction(
            id: "lint",
            name: "Lint",
            command: "npm",
            args: ["run", "lint"],
            workingDir: session.dir,
            timeoutSeconds: 30
        )
        let secondAction = AgentCommandAction(
            id: "test",
            name: "Test",
            command: "go",
            args: ["test", "./..."],
            workingDir: session.dir,
            timeoutSeconds: 60
        )
        let firstResult = CommandActionRunResponse(
            id: firstAction.id,
            name: firstAction.name,
            path: session.dir,
            workingDir: session.dir,
            command: firstAction.command,
            args: firstAction.args,
            success: true,
            exitCode: 0,
            output: "lint ok",
            truncated: false,
            timedOut: false,
            durationMS: 20
        )
        let secondResult = CommandActionRunResponse(
            id: secondAction.id,
            name: secondAction.name,
            path: session.dir,
            workingDir: session.dir,
            command: secondAction.command,
            args: secondAction.args,
            success: true,
            exitCode: 0,
            output: "test ok",
            truncated: false,
            timedOut: false,
            durationMS: 40
        )
        let client = DelayedCommandActionClient(
            projects: [project],
            sessions: [session],
            actionsByPath: [session.dir: [firstAction, secondAction]],
            runResults: [
                "\(session.dir)#\(firstAction.id)": .success(firstResult),
                "\(session.dir)#\(secondAction.id)": .success(secondResult)
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.refreshSelectedCommandActions()

        let runningTask = Task { await store.runSelectedCommandAction(firstAction) }
        await client.waitForRunRequestCount(1)

        XCTAssertEqual(store.runningCommandActionPath, session.dir)
        XCTAssertEqual(store.runningCommandActionID, firstAction.id)
        XCTAssertEqual(store.selectedQueuedCommandActionIDs, [])

        await store.runSelectedCommandAction(secondAction)

        XCTAssertEqual(client.requestedCommandActionRuns, [RequestedCommandActionRun(path: session.dir, id: firstAction.id, confirmed: false)])
        XCTAssertEqual(store.selectedQueuedCommandActionIDs, [secondAction.id])

        client.resolveRun(at: 0)
        await client.waitForRunRequestCount(2)

        XCTAssertEqual(store.runningCommandActionPath, session.dir)
        XCTAssertEqual(store.runningCommandActionID, secondAction.id)
        XCTAssertEqual(store.selectedQueuedCommandActionIDs, [])

        client.resolveRun(at: 1)
        await runningTask.value

        XCTAssertNil(store.runningCommandActionPath)
        XCTAssertNil(store.runningCommandActionID)
        XCTAssertEqual(
            client.requestedCommandActionRuns,
            [
                RequestedCommandActionRun(path: session.dir, id: firstAction.id, confirmed: false),
                RequestedCommandActionRun(path: session.dir, id: secondAction.id, confirmed: false)
            ]
        )
        XCTAssertEqual(store.selectedCommandActionHistory, [secondResult, firstResult])
        XCTAssertNil(store.selectedCommandActionErrorMessage)
    }

    func testSessionStoreRefreshesCapabilitiesForSelectedPath() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_caps", projectID: project.id, title: "能力", status: "history", source: "codex", resumeID: "caps")
        let response = CapabilityListResponse(
            path: session.dir,
            skills: [
                SkillCapability(name: "review", description: "Review changes", scope: "repo", path: "\(session.dir)/.agents/skills/review/SKILL.md", enabled: true)
            ],
            mcpServers: [
                MCPCapability(name: "context7", scope: "user", configPath: "/Users/me/.codex/config.toml", transport: "stdio", command: "npx", url: nil, enabled: true, plugin: nil)
            ]
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            capabilityResults: [session.dir: .success(response)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.refreshCapabilities()

        XCTAssertEqual(client.requestedCapabilityPaths, [session.dir])
        XCTAssertEqual(store.capabilityList, response)
        XCTAssertNil(store.capabilityErrorMessage)
    }

    func testSessionStoreRefreshesWorktreeBranches() async {
        let project = makeProject(id: "proj_1")
        let response = WorktreeBranchListResponse(
            path: project.path,
            defaultBase: "main",
            currentBranch: "main",
            branches: [
                WorktreeBranchItem(name: "main", kind: "local", isCurrent: true, isDefault: true),
                WorktreeBranchItem(name: "origin/main", kind: "remote")
            ]
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            worktreeBranchResults: [project.path: .success(response)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshWorktreeBranches(path: " \(project.path) ")

        XCTAssertEqual(client.requestedWorktreeBranchPaths, [project.path])
        XCTAssertEqual(store.worktreeBranches(path: project.path), response)
        XCTAssertNil(store.worktreeBranchError(path: project.path))
    }

    func testSessionStoreCreatesWorktreeAndOpensReturnedWorkspace() async {
        let project = makeProject(id: "proj_1")
        let workspace = AgentWorkspace(
            id: "ws_worktree",
            name: "feature-review",
            path: "/tmp/worktrees/proj_1/feature-review",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let worktreeSession = makeSession(
            id: "codex_worktree",
            projectID: workspace.id,
            title: "Worktree 会话",
            status: "history",
            source: "codex",
            resumeID: "worktree"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectSessions: [project.id: [worktreeSession]],
            worktreeCreateResults: [
                project.path: .success(WorktreeCreateResponse(
                    workspace: workspace,
                    worktree: WorktreeDescriptor(
                        path: workspace.path,
                        repositoryPath: project.path,
                        base: "main",
                        branch: "mimi/feature-review",
                        rootProjectID: project.id,
                        rootProjectName: project.name,
                        rootProjectPath: project.path
                    )
                ))
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let opened = await store.createWorktreeAndOpen(
            project: project,
            name: " feature-review ",
            base: " main ",
            branch: " mimi/feature-review "
        )

        XCTAssertTrue(opened)
        XCTAssertEqual(client.requestedWorktreeCreates, [
            RequestedWorktreeCreate(path: project.path, name: "feature-review", base: "main", branch: "mimi/feature-review")
        ])
        XCTAssertEqual(store.selectedProjectID, workspace.id)
        XCTAssertEqual(store.selectedProject?.path, workspace.path)
        XCTAssertEqual(client.requestedWorkspaceIDs.last, workspace.id)
        XCTAssertEqual(store.filteredSidebarProjects.map(\.id).contains(workspace.id), true)
        XCTAssertEqual(store.managedWorktrees.map(\.workspace.id), [workspace.id])
    }

    func testSessionStoreHandoffsSessionWithNativeForkWhenAvailable() async {
        let project = makeProject(id: "proj_1")
        let source = makeSession(
            id: "codex_source",
            projectID: project.id,
            title: "审核修复",
            status: "history",
            source: "codex",
            resumeID: "thread_source"
        )
        let workspace = AgentWorkspace(
            id: "ws_handoff",
            name: "audit-handoff",
            path: "/tmp/worktrees/proj_1/audit-handoff",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let forked = makeSession(
            id: "thread_forked",
            projectID: workspace.id,
            title: "Forked",
            status: "history",
            source: "codex",
            resumeID: "thread_forked"
        )
        let descriptor = WorktreeDescriptor(
            path: workspace.path,
            repositoryPath: project.path,
            base: "main",
            branch: "mimi/audit-handoff",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [source],
            sessionForkResults: [
                "thread_source": .success(forked)
            ],
            worktreeCreateResults: [
                project.path: .success(WorktreeCreateResponse(workspace: workspace, worktree: descriptor))
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let handedOff = await store.handoffSessionToWorktree(source, name: "audit handoff")

        XCTAssertTrue(handedOff)
        XCTAssertEqual(client.requestedSessionForks, [
            RequestedSessionFork(threadID: "thread_source", workspaceID: workspace.id)
        ])
        XCTAssertTrue(client.createPayloads.isEmpty)
        XCTAssertEqual(store.selectedProjectID, workspace.id)
        XCTAssertEqual(store.selectedSessionID, forked.id)
        XCTAssertEqual(store.managedWorktrees.map(\.workspace.id), [workspace.id])
    }

    func testSessionStoreHandoffsSessionToNewWorktree() async throws {
        let project = makeProject(id: "proj_1")
        let source = makeSession(
            id: "codex_source",
            projectID: project.id,
            title: "审核修复",
            status: "history",
            source: "codex",
            resumeID: "thread_source",
            preview: "继续处理审核问题"
        )
        let workspace = AgentWorkspace(
            id: "ws_handoff",
            name: "audit-handoff",
            path: "/tmp/worktrees/proj_1/audit-handoff",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let created = makeSession(
            id: "codex_handoff",
            projectID: workspace.id,
            title: "Worktree Handoff",
            status: "running",
            source: "codex"
        )
        let descriptor = WorktreeDescriptor(
            path: workspace.path,
            repositoryPath: project.path,
            base: "main",
            branch: "mimi/audit-handoff",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [source],
            createSessionResponse: try makeCreateSessionResponse(session: created),
            worktreeCreateResults: [
                project.path: .success(WorktreeCreateResponse(workspace: workspace, worktree: descriptor))
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let handedOff = await store.handoffSessionToWorktree(
            source,
            name: " audit handoff ",
            base: " main ",
            branch: " mimi/audit-handoff "
        )

        XCTAssertTrue(handedOff)
        XCTAssertEqual(client.requestedWorktreeCreates, [
            RequestedWorktreeCreate(path: project.path, name: "audit handoff", base: "main", branch: "mimi/audit-handoff")
        ])
        XCTAssertEqual(client.requestedSessionForks, [
            RequestedSessionFork(threadID: "thread_source", workspaceID: workspace.id)
        ])
        XCTAssertEqual(client.createPayloads.count, 1)
        guard let payload = client.createPayloads.first else {
            return XCTFail("handoff 应创建一个新会话")
        }
        XCTAssertEqual(payload.projectID, workspace.id)
        XCTAssertEqual(payload.projectPath, workspace.path)
        XCTAssertEqual(payload.rootProjectID, project.id)
        XCTAssertEqual(payload.resumeID, "")
        XCTAssertEqual(payload.turnOptions.sessionStartSource, "mimi_remote_worktree_handoff")
        XCTAssertEqual(payload.turnOptions.threadSource, "worktree_handoff")
        XCTAssertTrue(payload.prompt.contains("线程 ID：thread_source"))
        XCTAssertTrue(payload.prompt.contains("原工作区：\(project.path)"))
        XCTAssertTrue(payload.prompt.contains("路径：\(workspace.path)"))
        XCTAssertEqual(store.selectedProjectID, workspace.id)
        XCTAssertEqual(store.selectedSessionID, created.id)
        XCTAssertEqual(store.managedWorktrees.map(\.workspace.id), [workspace.id])
    }

    func testSessionStoreRejectsRunningSessionWorktreeHandoff() async {
        let project = makeProject(id: "proj_1")
        let running = makeSession(
            id: "codex_running",
            projectID: project.id,
            title: "运行中",
            status: "running",
            source: "codex"
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let handedOff = await store.handoffSessionToWorktree(running)

        XCTAssertFalse(handedOff)
        XCTAssertTrue(client.requestedWorktreeCreates.isEmpty)
        XCTAssertEqual(store.errorMessage, "运行中的会话不能直接转到 Worktree，请先停止或等待完成。")
    }

    func testSessionStoreRefreshesOpensAndDeletesManagedWorktree() async {
        let project = makeProject(id: "proj_1")
        let workspace = AgentWorkspace(
            id: "ws_worktree",
            name: "feature-review",
            path: "/tmp/worktrees/proj_1/feature-review",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let item = WorktreeListItem(
            workspace: workspace,
            worktree: WorktreeDescriptor(
                path: workspace.path,
                repositoryPath: project.path,
                base: "HEAD",
                branch: "mimi/feature-review",
                rootProjectID: project.id,
                rootProjectName: project.name,
                rootProjectPath: project.path
            )
        )
        let worktreeSession = makeSession(
            id: "codex_worktree",
            projectID: workspace.id,
            title: "Worktree 会话",
            status: "history",
            source: "codex",
            resumeID: "worktree"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            workspaceSessions: [workspace.id: [worktreeSession]],
            worktreeListResult: .success([item]),
            worktreeDeleteResults: [
                workspace.path: .success(WorktreeDeleteResponse(
                    deletedPath: workspace.path,
                    worktrees: [],
                    workspace: nil,
                    worktree: nil
                ))
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.refreshManagedWorktrees()
        let opened = await store.openManagedWorktree(item)
        let deleted = await store.deleteManagedWorktree(item)

        XCTAssertTrue(opened)
        XCTAssertTrue(deleted)
        XCTAssertEqual(client.worktreeListCallCount, 1)
        XCTAssertEqual(client.requestedWorkspaceIDs.last, workspace.id)
        XCTAssertEqual(client.requestedWorktreeDeletes, [
            RequestedWorktreeDelete(path: workspace.path, force: false)
        ])
        XCTAssertTrue(store.managedWorktrees.isEmpty)
        XCTAssertNil(store.selectedProjectID)
        XCTAssertFalse(store.filteredSidebarProjects.map(\.id).contains(workspace.id))
    }

    func testSessionStoreDoesNotDeleteRunningManagedWorktree() async {
        let project = makeProject(id: "proj_1")
        let workspace = AgentWorkspace(
            id: "ws_worktree",
            name: "feature-review",
            path: "/tmp/worktrees/proj_1/feature-review",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let item = WorktreeListItem(
            workspace: workspace,
            worktree: WorktreeDescriptor(
                path: workspace.path,
                repositoryPath: project.path,
                base: "HEAD",
                branch: "mimi/feature-review",
                rootProjectID: project.id,
                rootProjectName: project.name,
                rootProjectPath: project.path
            )
        )
        let runningSession = makeSession(
            id: "codex_running_worktree",
            projectID: workspace.id,
            title: "运行中",
            status: "running",
            source: "codex",
            resumeID: "running"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            workspaceSessions: [workspace.id: [runningSession]],
            worktreeListResult: .success([item])
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.refreshManagedWorktrees()
        _ = await store.openManagedWorktree(item)
        let deleted = await store.deleteManagedWorktree(item)

        XCTAssertFalse(deleted)
        XCTAssertTrue(client.requestedWorktreeDeletes.isEmpty)
        XCTAssertEqual(store.worktreeErrorMessage, "该 Worktree 还有运行中的会话，先停止会话后再删除。")
    }

    func testSessionStorePrunesMissingManagedWorktreeRegistry() async {
        let project = makeProject(id: "proj_1")
        let workspace = AgentWorkspace(
            id: "ws_worktree",
            name: "feature-review",
            path: "/tmp/worktrees/proj_1/feature-review",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let item = WorktreeListItem(
            workspace: workspace,
            worktree: WorktreeDescriptor(
                path: workspace.path,
                repositoryPath: project.path,
                base: "main",
                branch: "mimi/feature-review",
                rootProjectID: project.id,
                rootProjectName: project.name,
                rootProjectPath: project.path
            )
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            worktreeListResult: .success([item]),
            worktreePruneResult: .success(WorktreePruneResponse(prunedPaths: [workspace.path], worktrees: []))
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.refreshManagedWorktrees()
        let prunedCount = await store.pruneMissingManagedWorktrees()

        XCTAssertEqual(prunedCount, 1)
        XCTAssertEqual(client.worktreePruneCallCount, 1)
        XCTAssertTrue(store.managedWorktrees.isEmpty)
        XCTAssertNil(store.worktreeErrorMessage)
    }

    func testSessionStoreProjectIndexKeepsPreviousSelectionAfterRefresh() async {
        let firstProject = makeProject(id: "proj_1")
        let secondProject = makeProject(id: "proj_2")
        let client = MockSessionStoreClient(projects: [firstProject, secondProject], sessions: [])
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = secondProject.id
        await store.refreshAll(autoAttach: false)

        XCTAssertEqual(store.selectedProject?.id, secondProject.id)
        XCTAssertEqual(store.selectedProjectID, secondProject.id)
    }

    func testRepeatedProjectRefreshDoesNotPublishUnchangedProjections() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = MockSessionStoreClient(projects: [project], sessions: [history])
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        var publishCount = 0
        var cancellables: Set<AnyCancellable> = []
        store.objectWillChange
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        await store.refreshAll(autoAttach: false)

        // 相同 projects/sessions/status 不应重复下发；这里只保留 loading true/false 两次真实状态变化。
        XCTAssertEqual(publishCount, 2)
        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertEqual(store.filteredSessions.map(\.id), [history.id])
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

    func testAgentSessionDropsStalePendingApprovalOutsideWaitingStatus() {
        let approval = ApprovalSummary(id: "approval-stale", title: "运行 xcodebuild", kind: "command", count: 1)

        let running = AgentSession(
            id: "codex_running",
            projectID: "proj_1",
            project: "proj_1",
            dir: "/tmp/proj_1",
            title: "运行中",
            status: "running",
            source: "codex",
            resumeID: "running",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            pendingApproval: approval
        )
        XCTAssertNil(running.pendingApproval)

        let waiting = AgentSession(
            id: "codex_waiting",
            projectID: "proj_1",
            project: "proj_1",
            dir: "/tmp/proj_1",
            title: "等待审批",
            status: "waiting_for_approval",
            source: "codex",
            resumeID: "waiting",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            pendingApproval: approval
        )
        XCTAssertEqual(waiting.pendingApproval?.id, approval.id)
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

    func testSelectingSessionRevealsOwningProjectInSidebar() async {
        let firstProject = makeProject(id: "proj_1")
        let secondProject = makeProject(id: "proj_2")
        let secondSession = makeSession(id: "sess_second", projectID: secondProject.id, title: "第二项目会话", status: "closed", source: "codex")
        let client = MockSessionStoreClient(
            projects: [firstProject, secondProject],
            sessions: [],
            projectSessions: [
                firstProject.id: [],
                secondProject.id: [secondSession]
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.toggleProjectExpansion(secondProject)
        await store.toggleProjectExpansion(secondProject)
        XCTAssertFalse(store.isProjectExpanded(secondProject.id))

        await store.selectSession(secondSession)

        XCTAssertEqual(store.selectedProjectID, secondProject.id)
        XCTAssertEqual(store.selectedSessionID, secondSession.id)
        XCTAssertTrue(store.isProjectExpanded(secondProject.id))
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

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)

        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).map(\.id), ["codex_0", "codex_1", "codex_2"])
        XCTAssertEqual(store.hiddenSessionCount(forProjectID: project.id), 2)
        var snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertFalse(snapshot.isShowingAll)
        XCTAssertEqual(snapshot.visibleSessions.map(\.id), ["codex_0", "codex_1", "codex_2"])
        XCTAssertEqual(snapshot.allSessionCount, 5)
        XCTAssertEqual(snapshot.hiddenCount, 2)
        XCTAssertTrue(snapshot.shouldShowActionRow)
        XCTAssertEqual(snapshot.actionTitle, "显示更多")

        await store.toggleSessionListExpansion(projectID: project.id)
        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).count, 5)
        XCTAssertEqual(store.hiddenSessionCount(forProjectID: project.id), 0)
        snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertTrue(snapshot.isShowingAll)
        XCTAssertEqual(snapshot.visibleSessions.count, 5)
        XCTAssertTrue(snapshot.shouldShowActionRow)
        XCTAssertEqual(snapshot.actionTitle, "收起显示")

        await store.toggleSessionListExpansion(projectID: project.id)
        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).map(\.id), ["codex_0", "codex_1", "codex_2"])
        snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertFalse(snapshot.isShowingAll)
        XCTAssertEqual(snapshot.visibleSessions.map(\.id), ["codex_0", "codex_1", "codex_2"])
    }

    func testSessionStoreExpandsProjectSessionsInSmallSteps() async {
        let project = makeProject(id: "proj_step_expand")
        let sessions = (0..<12).map { index in
            makeSession(
                id: "codex_step_\(index)",
                projectID: project.id,
                title: "历史 \(index)",
                status: "history",
                source: "codex",
                resumeID: "history_step_\(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let client = MockSessionStoreClient(projects: [project], sessions: sessions)
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).count, SessionStore.sessionPreviewLimit)

        await store.toggleSessionListExpansion(projectID: project.id)
        var snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertEqual(snapshot.visibleSessions.count, SessionStore.sessionPreviewLimit + SessionStore.sessionExpansionStep)
        XCTAssertEqual(snapshot.hiddenCount, 4)
        XCTAssertEqual(snapshot.actionTitle, "显示更多")

        await store.toggleSessionListExpansion(projectID: project.id)
        snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertEqual(snapshot.visibleSessions.count, 12)
        XCTAssertEqual(snapshot.hiddenCount, 0)
        XCTAssertEqual(snapshot.actionTitle, "收起显示")
    }

    func testSessionStoreLoadsNextSessionPageWhenExpanded() async {
        let project = makeProject(id: "proj_1")
        let firstPage = (0..<3).map { index in
            makeSession(
                id: "codex_first_\(index)",
                projectID: project.id,
                title: "第一页 \(index)",
                status: "history",
                source: "codex",
                resumeID: "first_\(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(20 - index))
            )
        }
        let secondPage = (0..<2).map { index in
            makeSession(
                id: "codex_second_\(index)",
                projectID: project.id,
                title: "第二页 \(index)",
                status: "history",
                source: "codex",
                resumeID: "second_\(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(10 - index))
            )
        }
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectPages: [
                project.id: SessionsPage(sessions: firstPage, nextCursor: "cursor_1", hasMore: true)
            ],
            cursorPages: [
                "cursor_1": SessionsPage(sessions: secondPage, hasMore: false)
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        XCTAssertTrue(store.canLoadMoreSessions(projectID: project.id))
        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).map(\.id), firstPage.map(\.id))
        var snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertFalse(snapshot.isShowingAll)
        XCTAssertTrue(snapshot.canLoadMore)
        XCTAssertTrue(snapshot.shouldShowActionRow)
        XCTAssertEqual(snapshot.actionTitle, "显示更多")

        await store.toggleSessionListExpansion(projectID: project.id)

        XCTAssertFalse(store.canLoadMoreSessions(projectID: project.id))
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), (firstPage + secondPage).map(\.id))
        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).count, 5)
        snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertTrue(snapshot.isShowingAll)
        XCTAssertFalse(snapshot.canLoadMore)
        XCTAssertEqual(snapshot.allSessionCount, 5)
        XCTAssertEqual(snapshot.visibleSessions.count, 5)
        XCTAssertTrue(snapshot.shouldShowActionRow)
        XCTAssertEqual(snapshot.actionTitle, "收起显示")
    }

    func testSessionStoreKeepsNewestVisibleAfterLoadingOlderPageAndRefreshing() async {
        let project = makeProject(id: "proj_sidebar_paging")
        let firstPage = (0..<8).map { index in
            makeSession(
                id: "codex_latest_\(index)",
                projectID: project.id,
                title: "最近会话 \(index)",
                status: "history",
                source: "codex",
                resumeID: "latest_\(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let olderPage = [
            makeSession(
                id: "codex_older_0",
                projectID: project.id,
                title: "更早会话",
                status: "history",
                source: "codex",
                resumeID: "older_0",
                updatedAt: Date(timeIntervalSince1970: 90)
            )
        ]
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: firstPage, nextCursor: "cursor_older", hasMore: true),
            cursorPages: ["cursor_older": SessionsPage(sessions: olderPage, hasMore: false)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.toggleSessionListExpansion(projectID: project.id)
        await store.toggleSessionListExpansion(projectID: project.id)

        var snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertEqual(snapshot.visibleSessions.map(\.id), (firstPage + olderPage).map(\.id))
        XCTAssertEqual(snapshot.visibleSessions.first?.id, firstPage.first?.id)
        XCTAssertEqual(snapshot.visibleSessions.last?.id, olderPage.first?.id)

        // 后台首屏刷新只能更新最新页状态，不能把用户已展开加载出的旧页收回。
        await store.refreshSelectedProjectSessions(showLoading: false)

        snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertEqual(snapshot.visibleSessions.map(\.id), (firstPage + olderPage).map(\.id))
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), (firstPage + olderPage).map(\.id))
    }

    func testSessionListSnapshotUpdatesWhenPaginationStateChangesWithoutSessionDiff() async {
        let project = makeProject(id: "proj_1")
        let firstPage = (0..<3).map { index in
            makeSession(
                id: "codex_first_\(index)",
                projectID: project.id,
                title: "第一页 \(index)",
                status: "history",
                source: "codex",
                resumeID: "first_\(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(20 - index))
            )
        }
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: firstPage, nextCursor: "cursor_1", hasMore: true)
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        var snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertTrue(snapshot.canLoadMore)
        XCTAssertTrue(snapshot.shouldShowActionRow)
        XCTAssertEqual(snapshot.actionTitle, "显示更多")

        client.page = SessionsPage(sessions: firstPage, hasMore: false)
        await store.refreshAll(autoAttach: false)

        snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertFalse(snapshot.canLoadMore)
        XCTAssertFalse(snapshot.shouldShowActionRow)
        XCTAssertEqual(snapshot.visibleSessions.map(\.id), firstPage.map(\.id))
    }

    func testSessionStoreDerivedSessionIndexesStaySortedAfterUpsert() async throws {
        let project = makeProject(id: "proj_1")
        let older = makeSession(
            id: "codex_older",
            projectID: project.id,
            title: "旧历史",
            status: "history",
            source: "codex",
            resumeID: "older",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = makeSession(
            id: "codex_newer",
            projectID: project.id,
            title: "新历史",
            status: "history",
            source: "codex",
            resumeID: "newer",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let created = makeSession(id: "sess_created", projectID: project.id, title: "刚创建", status: "closed", source: "codex")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectSessions: [project.id: [older, newer]],
            createSessionResponse: try makeCreateSessionResponse(session: created)
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).map(\.id), [newer.id, older.id])

        // upsert 只发布一次 sessions，同时必须重建派生索引；否则侧栏会继续显示旧排序。
        await store.startNewSession(in: project)

        XCTAssertEqual(store.selectedSession?.id, created.id)
        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).map(\.id), [created.id, newer.id, older.id])
        XCTAssertEqual(store.filteredSessions.map(\.id), [created.id, newer.id, older.id])
    }

    func testStartingEmptyInteractiveSessionDoesNotAutoLoadHistory() async throws {
        let project = makeProject(id: "proj_1")
        let created = makeSession(id: "sess_created_running", projectID: project.id, title: "刚创建", status: "running", source: "codex")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            createSessionResponse: try makeCreateSessionResponse(session: created),
            messagesError: AgentAPIError.server(status: 504, message: "thread/read timeout")
        )
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.startNewSession(in: project)

        XCTAssertEqual(client.createPayloads.count, 1)
        XCTAssertTrue(client.requestedMessageSessionIDs.isEmpty)
        XCTAssertEqual(store.selectedSession?.id, created.id)
        XCTAssertNil(store.selectedHistorySavingsNotice)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(conversationStore.messages(for: created.id).map(\.content), ["交互式会话已启动。"])
        XCTAssertEqual(sockets.count, 1)
    }

    // 回归：新建会话在创建瞬间就绑定 runtime。入口显式选择 Claude 时，createSession 请求必须
    // 携带 runtimeProvider=claude，否则空线程会落在默认 Codex 通道上且事后无法迁移。
    func testStartNewSessionWithClaudeRuntimeCarriesRuntimeProviderInCreatePayload() async throws {
        let project = makeProject(id: "proj_claude_entry")
        let created = makeSession(id: "claude_created", projectID: project.id, title: "Claude 会话", status: "closed", source: "claude")
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

        await store.startNewSession(in: project, runtimeProvider: "claude")

        XCTAssertEqual(client.createPayloads.count, 1)
        let payload = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(
            CodexAppServerSessionRuntime.normalizedRuntimeProvider(payload.turnOptions.runtimeProvider),
            "claude",
            "显式 Claude 入口创建的空线程必须路由到 Claude runtime"
        )
        XCTAssertEqual(store.selectedSession?.id, created.id)

        // 默认入口保持 Codex 主线行为：不显式携带 claude runtimeProvider。
        await store.startNewSession(in: project)
        XCTAssertEqual(client.createPayloads.count, 2)
        let defaultPayload = try XCTUnwrap(client.createPayloads.last)
        XCTAssertNotEqual(
            CodexAppServerSessionRuntime.normalizedRuntimeProvider(defaultPayload.turnOptions.runtimeProvider),
            "claude",
            "默认新建会话不能被 Claude 修复改变通道"
        )
    }

    func testSessionStoreUsesIDTieBreakerForMatchingBackendCursorOrder() async {
        let project = makeProject(id: "proj_1")
        let sameUpdatedAt = Date(timeIntervalSince1970: 20)
        let sessions = [
            makeSession(id: "codex_alpha", projectID: project.id, title: "Z Title", status: "history", source: "codex", resumeID: "alpha", updatedAt: sameUpdatedAt),
            makeSession(id: "codex_beta", projectID: project.id, title: "A Title", status: "history", source: "codex", resumeID: "beta", updatedAt: sameUpdatedAt),
            makeSession(id: "codex_gamma", projectID: project.id, title: "M Title", status: "history", source: "codex", resumeID: "gamma", updatedAt: sameUpdatedAt)
        ]
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectSessions: [project.id: sessions]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)

        // Go 后端 cursor 按 updated_at desc + id desc；Swift 派生索引必须保持同序，
        // 否则分页合并后本地会按标题重排，出现侧栏跳动。
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), ["codex_gamma", "codex_beta", "codex_alpha"])
    }

    func testSessionStoreFreezesProjectOrderWhileSessionIsRunning() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(
            id: "codex_history",
            projectID: project.id,
            title: "历史",
            status: "history",
            source: "codex",
            resumeID: "history",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let running = makeSession(
            id: "sess_running",
            projectID: project.id,
            title: "运行中",
            status: "running",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let client = MutableSessionPageClient(projects: [project], page: SessionsPage(sessions: [history, running]))
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [history.id, running.id])

        client.page = SessionsPage(sessions: [
            history,
            makeSession(
                id: running.id,
                projectID: project.id,
                title: running.title,
                status: "running",
                source: running.source,
                updatedAt: Date(timeIntervalSince1970: 30)
            )
        ])
        await store.refreshSelectedProjectSessions()

        // running 输出刷新会更新 updatedAt；侧栏保持用户正在看的相对顺序，避免列表来回跳。
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [history.id, running.id])

        client.page = SessionsPage(sessions: [
            history,
            makeSession(
                id: running.id,
                projectID: project.id,
                title: running.title,
                status: "closed",
                source: running.source,
                updatedAt: Date(timeIntervalSince1970: 30)
            )
        ])
        await store.refreshSelectedProjectSessions()

        // 没有 running session 后释放冻结顺序，恢复 updatedAt 排序。
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [running.id, history.id])
    }

    func testLocalSendUpdatesSessionPreviewAfterRemoteMacPreview() async throws {
        let project = makeProject(id: "proj_projection_send")
        let remoteUpdatedAt = Date(timeIntervalSince1970: 20)
        let running = makeSession(
            id: "sess_projection_send",
            projectID: project.id,
            title: "混合端会话",
            status: "running",
            source: "codex",
            preview: "Mac 端刚回复的摘要",
            updatedAt: remoteUpdatedAt
        )
        let client = MutableSessionPageClient(projects: [project], page: SessionsPage(sessions: [running]))
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let didSend = await store.sendPrompt("iPad 继续下一步")
        XCTAssertTrue(didSend)

        XCTAssertEqual(store.selectedSession?.preview, "iPad 继续下一步")
        XCTAssertEqual(store.sessions(forProjectID: project.id).first?.preview, "iPad 继续下一步")
    }

    func testStaleRemoteSnapshotDoesNotOverwriteLocalProjection() async throws {
        let project = makeProject(id: "proj_projection_stale")
        let remoteUpdatedAt = Date(timeIntervalSince1970: 20)
        let running = makeSession(
            id: "sess_projection_stale",
            projectID: project.id,
            title: "混合端会话",
            status: "running",
            source: "codex",
            preview: "Mac 端旧摘要",
            updatedAt: remoteUpdatedAt
        )
        let client = MutableSessionPageClient(projects: [project], page: SessionsPage(sessions: [running]))
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        let didSend = await store.sendPrompt("iPad 新输入")
        XCTAssertTrue(didSend)

        client.page = SessionsPage(sessions: [
            makeSession(
                id: running.id,
                projectID: project.id,
                title: running.title,
                status: "running",
                source: running.source,
                preview: "Mac 端旧摘要",
                updatedAt: remoteUpdatedAt
            )
        ])
        await store.refreshSelectedProjectSessions()

        XCTAssertEqual(store.selectedSession?.preview, "iPad 新输入")
    }

    func testFreshRemoteSnapshotClearsLocalProjection() async throws {
        let project = makeProject(id: "proj_projection_fresh")
        let remoteUpdatedAt = Date(timeIntervalSince1970: 20)
        let running = makeSession(
            id: "sess_projection_fresh",
            projectID: project.id,
            title: "混合端会话",
            status: "running",
            source: "codex",
            preview: "Mac 端旧摘要",
            updatedAt: remoteUpdatedAt
        )
        let client = MutableSessionPageClient(projects: [project], page: SessionsPage(sessions: [running]))
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        let didSend = await store.sendPrompt("iPad 新输入")
        XCTAssertTrue(didSend)

        client.page = SessionsPage(sessions: [
            makeSession(
                id: running.id,
                projectID: project.id,
                title: running.title,
                status: "running",
                source: running.source,
                preview: "后端已经追上的摘要",
                updatedAt: Date(timeIntervalSince1970: 21)
            )
        ])
        await store.refreshSelectedProjectSessions()

        for _ in 0..<80 where store.selectedSession?.preview != "后端已经追上的摘要" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.selectedSession?.preview, "后端已经追上的摘要")
    }

    func testFailedSocketSendRevertsLocalProjection() async throws {
        let project = makeProject(id: "proj_projection_fail")
        let running = makeSession(
            id: "sess_projection_fail",
            projectID: project.id,
            title: "失败回滚",
            status: "running",
            source: "codex",
            preview: "远端摘要",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let client = MutableSessionPageClient(projects: [project], page: SessionsPage(sessions: [running]))
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                socket.sendTurnResult = false
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let didSend = await store.sendPrompt("会失败的新输入")
        XCTAssertFalse(didSend)
        XCTAssertEqual(store.selectedSession?.preview, "远端摘要")
    }

    func testAssistantFinalUpdatesSessionPreview() async throws {
        let project = makeProject(id: "proj_projection_assistant")
        let running = makeSession(
            id: "sess_projection_assistant",
            projectID: project.id,
            title: "助手摘要",
            status: "running",
            source: "codex",
            preview: "旧摘要"
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: []) },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        sockets[0].emitEvent(.messageCompleted(
            AgentMessage(id: "assistant-final", sessionID: running.id, role: .assistant, content: "助手最终回复摘要", revision: 1),
            AgentEventMetadata(seq: 1, sessionID: running.id, turnID: "turn-1", itemID: "item-1", messageID: "assistant-final", clientMessageID: nil, revision: 1, createdAt: nil)
        ))
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(store.selectedSession?.preview, "助手最终回复摘要")
    }

    func testObservingRunningSessionBlocksSendTurn() async {
        let project = makeProject(id: "proj_observing")
        let running = makeSession(id: "sess_observing", projectID: project.id, title: "Mac 运行中", status: "running", source: "codex")
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: []) },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(running)

        XCTAssertTrue(store.isSelectedSessionObserving)
        let didSend = await store.sendPrompt("不应该发送")
        XCTAssertFalse(didSend)
        XCTAssertTrue(sockets.isEmpty)
        XCTAssertEqual(store.errorMessage, "这个会话正在其他客户端运行。请先接管到 iPad，再继续发送。")
    }

    func testTakenOverRunningSessionAllowsSendTurn() async throws {
        let project = makeProject(id: "proj_takeover")
        let running = makeSession(id: "sess_takeover", projectID: project.id, title: "接管运行中", status: "running", source: "codex")
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: []) },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let didSend = await store.sendPrompt("接管后发送")
        XCTAssertTrue(didSend)
        XCTAssertEqual(sockets[0].sentTurns.map { $0.payload.previewText }, ["接管后发送"])
    }

    func testHistorySessionContinueMarksTakenOver() async throws {
        let project = makeProject(id: "proj_history_takeover")
        let history = makeSession(
            id: "sess_history_takeover",
            projectID: project.id,
            title: "历史",
            status: "history",
            source: "codex",
            resumeID: "sess_history_takeover"
        )
        let resumed = makeSession(
            id: history.id,
            projectID: project.id,
            title: history.title,
            status: "running",
            source: "codex",
            resumeID: history.id
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            createSessionResponse: try makeCreateSessionResponse(session: resumed)
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)

        let didSend = await store.sendPrompt("继续历史")
        XCTAssertTrue(didSend)
        XCTAssertEqual(store.controlState(for: resumed), .takenOver)
        XCTAssertTrue(store.canControlSession(store.selectedSession))
    }

    func testHistorySessionContinueSuppressesBufferedMessageReplayAfterHistoryLoad() async throws {
        let project = makeProject(id: "proj_history_resume_replay")
        let history = makeSession(
            id: "sess_history_resume_replay",
            projectID: project.id,
            title: "历史",
            status: "history",
            source: "codex",
            resumeID: "sess_history_resume_replay"
        )
        let resumed = makeSession(
            id: history.id,
            projectID: project.id,
            title: history.title,
            status: "running",
            source: "codex",
            resumeID: history.id
        )
        let historyMessages = [
            CodexHistoryMessage(
                id: "appserver:turn-resume:item-1",
                role: "system",
                kind: .reasoningSummary,
                content: "历史中已有的过程卡",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: "turn-resume",
                itemID: "item-1"
            )
        ]
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            createSessionResponse: try makeCreateSessionResponse(session: resumed),
            historyPages: [resumed.id: HistoryMessagesPage(messages: historyMessages)]
        )
        var sockets: [MockWebSocketClient] = []
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)

        let didSend = await store.sendPrompt("继续历史")

        XCTAssertTrue(didSend)
        XCTAssertEqual(client.requestedMessageSessionIDs, [resumed.id])
        // 选中历史会话时就建立事件订阅（sockets[0]），resume 成功后切到运行连接（sockets[1]）；
        // 两次连接都已有 canonical 历史快照，都不应要求完整回放。
        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(sockets.map(\.replayBufferedEventsByConnect), [[false], [false]])
        XCTAssertTrue(conversationStore.hasLoadedHistory(sessionID: resumed.id))
        XCTAssertEqual(conversationStore.messages(for: resumed.id).filter { $0.kind == .reasoningSummary }.map(\.content), ["历史中已有的过程卡"])
    }

    func testRuntimeEventsDoNotBecomeSessionPreview() async throws {
        let project = makeProject(id: "proj_runtime_preview")
        let running = makeSession(
            id: "sess_runtime_preview",
            projectID: project.id,
            title: "运行日志",
            status: "running",
            source: "codex",
            preview: "用户可见摘要"
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: []) },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        sockets[0].emitEvent(.logDelta(
            LogDelta(text: "tool output should stay in log", stream: "stdout"),
            AgentEventMetadata(seq: 1, sessionID: running.id, turnID: "turn-1", itemID: "cmd-1", messageID: nil, clientMessageID: nil, revision: 1, createdAt: nil)
        ))
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(store.selectedSession?.preview, "用户可见摘要")
    }

    func testUTCBoundaryDisplaysUsingLocalDate() throws {
        let message = try AgentAPIClient.decoder.decode(
            CodexHistoryMessage.self,
            from: Data("""
            {
              "id": "utc-boundary",
              "role": "user",
              "content": "跨 UTC 午夜",
              "created_at": "2026-06-28T16:02:16Z"
            }
            """.utf8)
        )
        let createdAt = try XCTUnwrap(message.createdAt)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        XCTAssertEqual(formatter.string(from: createdAt), "2026-06-29 00:02:16")
    }

    func testSessionStoreIndexedUpsertReplacesExistingSessionWithoutDuplicate() async throws {
        let project = makeProject(id: "proj_1")
        let running = makeSession(
            id: "sess_running",
            projectID: project.id,
            title: "运行中",
            status: "running",
            source: "codex"
        )
        let closed = makeSession(
            id: running.id,
            projectID: project.id,
            title: running.title,
            status: "closed",
            source: running.source,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            sessionResponses: [
                running.id: try makeSessionResponse(session: closed, recentOutput: nil)
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(running)
        await store.refreshCurrentContext()
        try await Task.sleep(nanoseconds: 50_000_000)

        // session 高频状态更新走 ID->index 投影替换，不能退化成重复追加。
        XCTAssertEqual(store.sessions.filter { $0.id == running.id }.count, 1)
        XCTAssertEqual(store.selectedSession?.status, "closed")
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

    func testRefreshCurrentContextDoesNotWaitForSessionListReconciliation() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = BlockingSessionListRefreshClient(projects: [project], page: SessionsPage(sessions: [history]))
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)

        var refreshFinished = false
        let refreshTask = Task { @MainActor in
            await store.refreshCurrentContext()
            refreshFinished = true
        }

        await client.waitForBlockedSessionListRefresh()
        let finishedBeforeListRelease = refreshFinished
        client.releaseBlockedSessionListRefresh()
        await refreshTask.value

        XCTAssertTrue(finishedBeforeListRelease)
        XCTAssertEqual(client.requestedMessageCursors, [nil, nil])
    }

    func testSelectingHistoryWhileInitialPageLoadingDoesNotDuplicateRequest() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let firstSelectTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)

        store.returnToSessionList()
        let secondSelectTask = Task { await store.selectSession(history) }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(client.requestedMessageCursors, [nil])
        XCTAssertEqual(client.requestedMessageLimits, [20])
        XCTAssertEqual(client.requestedMessageLoadModes, [.full])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .loadingFull)

        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:100", role: "assistant", content: "首屏历史", createdAt: Date(timeIntervalSince1970: 10))
                ]
            )
        )
        await firstSelectTask.value
        await secondSelectTask.value

        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["首屏历史"])
        XCTAssertNil(store.selectedHistorySavingsNotice)
    }

    func testConcurrentRunningHistoryFirstPageLoadsCoalesceRequest() async {
        let project = makeProject(id: "proj_1")
        let running = makeSession(id: "codex_running", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [running]))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)

        let firstSelectTask = Task { await store.selectSession(running) }
        await client.waitForHistoryRequestCount(1)
        let secondSelectTask = Task { await store.selectSession(running) }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(client.requestedMessageCursors, [nil])
        XCTAssertEqual(client.requestedMessageLimits, [20])
        XCTAssertEqual(client.requestedMessageLoadModes, [.full])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .loadingFull)

        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:101", role: "assistant", content: "合并首屏历史", createdAt: Date(timeIntervalSince1970: 10))
                ]
            )
        )
        await firstSelectTask.value
        await secondSelectTask.value

        XCTAssertEqual(client.requestedMessageCursors, [nil])
        XCTAssertEqual(conversationStore.messages(for: running.id).map(\.content), ["合并首屏历史"])
        XCTAssertNil(store.selectedHistorySavingsNotice)
    }

    func testSummaryHistoryIsOnlyLoadedAfterUserChoosesIt() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_large", projectID: project.id, title: "大历史", status: "history", source: "codex", resumeID: "large")
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let fullTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)

        XCTAssertEqual(client.requestedMessageLoadModes, [.full])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .loadingFull)

        let firstSummaryTask = Task { await store.loadSummaryHistoryForSelectedSession() }
        await client.waitForHistoryRequestCount(2)
        let secondSummaryTask = Task { await store.loadSummaryHistoryForSelectedSession() }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .economy])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .loadingSummary)

        client.resolveHistoryRequest(
            at: 1,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:summary", role: "assistant", content: "缩略历史", createdAt: Date(timeIntervalSince1970: 20))
                ],
                loadMode: .economy,
                notice: "当前显示缩略历史。"
            )
        )
        await firstSummaryTask.value
        await secondSummaryTask.value

        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["缩略历史"])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .summaryLoaded)

        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:full", role: "assistant", content: "迟到完整历史", createdAt: Date(timeIntervalSince1970: 10))
                ]
            )
        )
        await fullTask.value

        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["缩略历史"])

        let reloadFullTask = Task { await store.loadFullHistoryForSelectedSession() }
        await client.waitForHistoryRequestCount(3)
        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .economy, .full])
        client.resolveHistoryRequest(
            at: 2,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:full-current", role: "assistant", content: "完整历史", createdAt: Date(timeIntervalSince1970: 30))
                ]
            )
        )
        await reloadFullTask.value

        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["完整历史"])
        XCTAssertNil(store.selectedHistorySavingsNotice)
    }

    func testFullHistoryPolicyFailureAutomaticallyLoadsSummaryHistory() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_auto_summary", projectID: project.id, title: "大历史自动降级", status: "history", source: "codex", resumeID: "large")
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let selectTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)

        XCTAssertEqual(client.requestedMessageLimits, [20])
        XCTAssertEqual(client.requestedMessageLoadModes, [.full])
        client.failHistoryRequest(at: 0, with: historyPolicyError(reason: "history_response_too_large"))

        await client.waitForHistoryRequestCount(2)
        XCTAssertEqual(client.requestedMessageLimits, [20, 60])
        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .economy])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .loadingSummary)

        client.resolveHistoryRequest(
            at: 1,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:auto-summary", role: "assistant", content: "自动缩略历史", createdAt: Date(timeIntervalSince1970: 20))
                ],
                loadMode: .economy,
                notice: "当前显示缩略历史。"
            )
        )
        await selectTask.value

        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["自动缩略历史"])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .summaryLoaded)
    }

    func testSummaryHistoryPolicyFailureRetriesOnceAfterRetryAfter() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_summary_retry", projectID: project.id, title: "缩略重试", status: "history", source: "codex", resumeID: "summary-retry")
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let selectTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)

        client.failHistoryRequest(at: 0, with: historyPolicyError(reason: "history_response_too_large"))
        await client.waitForHistoryRequestCount(2)

        client.failHistoryRequest(at: 1, with: historyPolicyError(reason: "history_budget_limited", retryAfterMs: 1))
        await client.waitForHistoryRequestCount(3)

        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .economy, .economy])
        XCTAssertEqual(client.requestedMessageLimits, [20, 60, 60])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .loadingSummary)

        client.resolveHistoryRequest(
            at: 2,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:summary-retry", role: "assistant", content: "重试后的缩略历史", createdAt: Date(timeIntervalSince1970: 30))
                ],
                loadMode: .economy,
                notice: "当前显示缩略历史。"
            )
        )
        await selectTask.value

        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["重试后的缩略历史"])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .summaryLoaded)
    }

    func testSummaryHistoryTerminalFailureShowsFailedNotice() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_summary_dead", projectID: project.id, title: "缩略失败", status: "history", source: "codex", resumeID: "summary-dead")
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let selectTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)

        client.failHistoryRequest(at: 0, with: historyPolicyError(reason: "history_response_too_large"))
        await client.waitForHistoryRequestCount(2)

        client.failHistoryRequest(at: 1, with: historyPolicyError(reason: "history_budget_limited", retryAfterMs: 1))
        await client.waitForHistoryRequestCount(3)

        // 重试额度用尽后再次失败：横幅必须离开“正在加载”，进入可重试的失败态。
        client.failHistoryRequest(at: 2, with: historyPolicyError(reason: "history_budget_limited", retryAfterMs: 1))
        await selectTask.value

        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .economy, .economy])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .summaryFailed)
        XCTAssertNotNil(store.errorMessage)
    }

    func testLoadEarlierHistoryMergesOlderMessagePage() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let newer = [
            CodexHistoryMessage(id: "rollout:200", role: "user", content: "较新的问题", createdAt: Date(timeIntervalSince1970: 20)),
            CodexHistoryMessage(id: "rollout:300", role: "assistant", content: "较新的回答", createdAt: Date(timeIntervalSince1970: 30))
        ]
        let older = [
            CodexHistoryMessage(id: "rollout:10", role: "user", content: "更早的问题", createdAt: Date(timeIntervalSince1970: 10))
        ]
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            historyPages: [
                history.id: HistoryMessagesPage(messages: newer, previousCursor: "older_cursor", hasMoreBefore: true)
            ],
            historyCursorPages: [
                "older_cursor": HistoryMessagesPage(messages: older, hasMoreBefore: false)
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
        await store.selectSession(history)

        XCTAssertTrue(store.canLoadEarlierHistory(sessionID: history.id))
        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["较新的问题", "较新的回答"])

        await store.loadEarlierHistoryForSelectedSession()

        XCTAssertFalse(store.canLoadEarlierHistory(sessionID: history.id))
        XCTAssertEqual(client.requestedMessageCursors, [nil, "older_cursor"])
        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["更早的问题", "较新的问题", "较新的回答"])
    }

    func testSessionStoreIngestsHistoryPageContextOnInitialLoadEarlierAndRefresh() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_context_history", projectID: project.id, title: "历史 context", status: "history", source: "codex", resumeID: "history")
        let initialContext = SessionContextSnapshot(
            sessionID: history.id,
            threadID: "thr_context_history",
            status: SessionContextStatus(type: "notLoaded"),
            tasks: [SessionContextTask(id: "cmd_initial", kind: "command", title: "go test ./...", subtitle: project.path, status: "completed")],
            sources: [SessionContextSource(id: "session_source", kind: "session", label: "vscode")]
        )
        let earlierContext = SessionContextSnapshot(
            sessionID: history.id,
            tasks: [SessionContextTask(id: "sub_earlier", kind: "subagent", title: "Zeno", subtitle: "review", status: "completed")],
            subagents: [SessionContextSubagent(id: "thr_child", parentThreadID: "thr_context_history", nickname: "Zeno", role: "review", status: "completed")]
        )
        let refreshContext = SessionContextSnapshot(
            sessionID: history.id,
            status: SessionContextStatus(type: "active"),
            tasks: [SessionContextTask(id: "web_refresh", kind: "web_search", title: "网络搜索：SwiftUI", status: "completed")]
        )
        let newer = [
            CodexHistoryMessage(id: "rollout:200", role: "assistant", content: "较新的回答", createdAt: Date(timeIntervalSince1970: 20))
        ]
        let older = [
            CodexHistoryMessage(id: "rollout:10", role: "user", content: "更早的问题", createdAt: Date(timeIntervalSince1970: 10))
        ]
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: [history]),
            historyPages: [
                history.id: HistoryMessagesPage(
                    messages: newer,
                    previousCursor: "older_cursor",
                    hasMoreBefore: true,
                    context: initialContext
                )
            ],
            historyCursorPages: [
                "older_cursor": HistoryMessagesPage(messages: older, hasMoreBefore: false, context: earlierContext)
            ]
        )
        let contextStore = SessionContextStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            contextStore: contextStore,
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)
        XCTAssertEqual(contextStore.context(for: history.id)?.tasks.map(\.id), ["cmd_initial"])
        XCTAssertEqual(contextStore.context(for: history.id)?.sources.first?.label, "vscode")

        await store.loadEarlierHistoryForSelectedSession()
        let taskIDsAfterEarlier = contextStore.context(for: history.id)?.tasks.map(\.id) ?? []
        XCTAssertEqual(Array(taskIDsAfterEarlier.prefix(2)), ["sub_earlier", "cmd_initial"])
        XCTAssertEqual(contextStore.context(for: history.id)?.subagents.first?.displayName, "Zeno")

        client.historyPages[history.id] = HistoryMessagesPage(messages: newer, hasMoreBefore: false, context: refreshContext)
        await store.refreshCurrentContext()

        let refreshed = contextStore.context(for: history.id)
        XCTAssertTrue(refreshed?.tasks.contains { $0.id == "web_refresh" && $0.kind == "web_search" } == true)
    }

    func testSessionInspectorSectionsCollapseDetailsLogsAndDiagnostics() {
        let descriptors = SessionInspectorSectionDescriptor.all

        XCTAssertEqual(descriptors.map(\.title), ["概览", "活动", "Git", "审批"])
        XCTAssertEqual(descriptors.map(\.id), ["context", "activity", "diff", "approval"])
        XCTAssertFalse(descriptors.contains { $0.title == "诊断" })
        XCTAssertFalse(descriptors.contains { $0.title == "详情" })
        XCTAssertFalse(descriptors.contains { $0.title == "日志" })
    }

    func testHistoryPagingStatePrunesWhenSessionLeavesList() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: [history]),
            historyPages: [
                history.id: HistoryMessagesPage(
                    messages: [
                        CodexHistoryMessage(id: "rollout:200", role: "assistant", content: "较新的回答", createdAt: Date(timeIntervalSince1970: 20))
                    ],
                    previousCursor: "older_cursor",
                    hasMoreBefore: true
                )
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)
        XCTAssertTrue(store.canLoadEarlierHistory(sessionID: history.id))

        store.returnToSessionList()
        client.page = SessionsPage(sessions: [])
        await store.refreshSelectedProjectSessions()

        XCTAssertFalse(store.canLoadEarlierHistory(sessionID: history.id))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testEmptyHistoryRefreshPreservesEarlierCursorUntilLoadEarlierReturnsEmpty() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let newer = [
            CodexHistoryMessage(id: "rollout:200", role: "user", content: "较新的问题", createdAt: Date(timeIntervalSince1970: 20))
        ]
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: [history]),
            historyPages: [
                history.id: HistoryMessagesPage(messages: newer, previousCursor: "older_cursor", hasMoreBefore: true)
            ],
            historyCursorPages: [
                "older_cursor": HistoryMessagesPage(messages: [], hasMoreBefore: false)
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
        await store.selectSession(history)
        XCTAssertTrue(store.canLoadEarlierHistory(sessionID: history.id))

        client.historyPages[history.id] = HistoryMessagesPage(messages: [], hasMoreBefore: false)
        await store.refreshCurrentContext()

        // 首屏刷新偶发空页时，不能把已有 older cursor 清掉，否则用户无法继续加载更早历史。
        XCTAssertTrue(store.canLoadEarlierHistory(sessionID: history.id))
        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["较新的问题"])

        await store.loadEarlierHistoryForSelectedSession()

        XCTAssertFalse(store.canLoadEarlierHistory(sessionID: history.id))
        XCTAssertEqual(client.requestedMessageCursors, [nil, nil, "older_cursor"])
    }

    func testManualRefreshReusesInFlightFullHistoryRequest() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let selectTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)

        let refreshTask = Task { await store.refreshCurrentContext() }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(client.requestedMessageCursors, [nil])
        XCTAssertEqual(client.requestedMessageLoadModes, [.full])

        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:200", role: "assistant", content: "新历史", createdAt: Date(timeIntervalSince1970: 20))
                ],
                previousCursor: "fresh_cursor",
                hasMoreBefore: true
            )
        )
        await refreshTask.value
        await selectTask.value

        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["新历史"])
        XCTAssertTrue(store.canLoadEarlierHistory(sessionID: history.id))
        XCTAssertEqual(client.requestedMessageCursors, [nil])
        XCTAssertEqual(client.requestedMessageLoadModes, [.full])
    }

    func testRefreshCurrentContextKeepsRunningRecentOutputInLogOnly() async throws {
        let project = makeProject(id: "proj_1")
        let running = makeSession(id: "sess_running", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            sessionResponses: [
                running.id: try makeSessionResponse(session: running, recentOutput: "│ • 从 Mac 回来的回复\n", lastSeq: 12)
            ],
            messagesResult: []
        )
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: logStore,
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.selectedSessionID = running.id
        await store.refreshCurrentContext()
        try await Task.sleep(nanoseconds: 1_100_000_000)

        XCTAssertEqual(client.requestedSessionIDs, [running.id])
        XCTAssertTrue(logStore.log(for: running.id).contains("从 Mac 回来的回复"))
        XCTAssertTrue(conversationStore.messages(for: running.id).isEmpty)
    }

    func testStructuredAssistantMessageCreatesBubble() async throws {
        let project = makeProject(id: "proj_1")
        let running = makeSession(id: "sess_structured_assistant_live", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: logStore,
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        XCTAssertEqual(sockets.count, 1)

        let assistant = try AgentAPIClient.decoder.decode(
            AgentMessage.self,
            from: Data("""
            {
              "id": "rollout:200",
              "session_id": "\(running.id)",
              "role": "assistant",
              "kind": "message",
              "content": "结构化助手回复",
              "created_at": "2026-06-02T10:00:00Z",
              "revision": 1,
              "send_status": "confirmed"
            }
            """.utf8)
        )
        sockets[0].emitEvent(.messageCompleted(
            assistant,
            AgentEventMetadata(seq: 2, sessionID: running.id, turnID: nil, itemID: nil, messageID: "rollout:200", clientMessageID: nil, revision: 1, createdAt: nil)
        ))
        try await Task.sleep(nanoseconds: 1_100_000_000)

        let messages = conversationStore.messages(for: running.id)
        XCTAssertTrue(logStore.log(for: running.id).isEmpty)
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.content == "结构化助手回复" })
    }

    func testRefreshCurrentContextRequestsRunningDetailAfterLocalLogSeq() async throws {
        let project = makeProject(id: "proj_1")
        let running = makeSession(id: "sess_running", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            sessionResponses: [
                running.id: try makeSessionResponse(session: running, recentOutput: nil, lastSeq: 12)
            ],
            messagesResult: []
        )
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        logStore.append("本地已有输出", sessionID: running.id, seq: 12)
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: logStore,
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.selectedSessionID = running.id
        await store.refreshCurrentContext()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(client.requestedSessionIDs, [running.id])
        XCTAssertEqual(client.requestedSessionAfterSeqs, [12])
        XCTAssertTrue(conversationStore.messages(for: running.id).isEmpty)
    }

    func testWebSocketMessageLimitAllowsLargeAppServerFrames() throws {
        let task = URLSession.shared.webSocketTask(with: try XCTUnwrap(URL(string: "ws://127.0.0.1:9/ws")))
        defer {
            task.cancel(with: .goingAway, reason: nil)
        }

        WebSocketMessageLimits.apply(to: task)

        XCTAssertEqual(task.maximumMessageSize, WebSocketMessageLimits.maximumInboundMessageBytes)
        XCTAssertGreaterThanOrEqual(WebSocketMessageLimits.maximumInboundMessageBytes, 64 * 1024 * 1024)
    }

    func testTerminalStreamStoreBatchesRuntimeEventsBySession() async {
        let store = TerminalStreamStore(maxBatchSize: 2)
        let metadata = AgentEventMetadata(
            seq: 1,
            sessionID: "sess_batch",
            turnID: nil,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )

        let firstShouldFlush = await store.append(.turnStarted(metadata), sessionID: "sess_batch")
        let secondShouldFlush = await store.append(.assistantDelta(AgentDelta(text: "hi", role: .assistant, kind: .message), metadata), sessionID: "sess_batch")

        XCTAssertFalse(firstShouldFlush)
        XCTAssertTrue(secondShouldFlush)
        let drained = await store.drain(sessionID: "sess_batch")
        let drainedAgain = await store.drain(sessionID: "sess_batch")
        XCTAssertEqual(drained.count, 2)
        XCTAssertTrue(drainedAgain.isEmpty)
    }

    func testDisconnectFlushesBufferedRuntimeEventsBeforeSwitchingSession() async throws {
        let project = makeProject(id: "proj_ws_disconnect_flush")
        let running = makeSession(id: "sess_ws_disconnect_flush", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let history = makeSession(id: "sess_ws_disconnect_history", projectID: project.id, title: "历史", status: "history", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running, history], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let assistant = try AgentAPIClient.decoder.decode(
            AgentMessage.self,
            from: Data("""
            {
              "id": "rollout:disconnect-flush",
              "session_id": "\(running.id)",
              "role": "assistant",
              "kind": "message",
              "content": "断开前最后一条回复",
              "created_at": "2026-06-02T10:00:00Z",
              "revision": 1,
              "send_status": "confirmed"
            }
            """.utf8)
        )
        sockets[0].emitEvent(.messageCompleted(
            assistant,
            AgentEventMetadata(seq: 7, sessionID: running.id, turnID: "turn-flush", itemID: "item-flush", messageID: assistant.id, clientMessageID: nil, revision: 1, createdAt: nil)
        ))

        await store.selectSession(history)

        let messages = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            messages.contains { $0.role == .assistant && $0.content == "断开前最后一条回复" }
        }
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.content == "断开前最后一条回复" })
        XCTAssertEqual(sockets[0].disconnectCallCount, 1)
    }

    func testWebSocketFailureAutoReconnectsWithLatestReplayWatermark() async throws {
        let project = makeProject(id: "proj_ws_reconnect")
        let running = makeSession(id: "sess_ws_reconnect", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let logStore = LogStore()
        logStore.append("旧输出", sessionID: running.id, seq: 5)
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: logStore,
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(sockets[0].connectedSessionIDs, [running.id])
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        logStore.append("新输出", sessionID: running.id, seq: 7)
        sockets[0].emitStatus(.failed("network dropped"))
        for _ in 0..<50 where sockets.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(client.requestedSessionAfterSeqs, [7])
        XCTAssertEqual(sockets[1].connectedSessionIDs, [running.id])
        sockets[1].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
    }

    func testWebSocketAutoReconnectDoesNotGiveUpWhileSessionStaysRunning() async throws {
        let project = makeProject(id: "proj_ws_persistent_reconnect")
        let running = makeSession(id: "sess_ws_persistent_reconnect", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        XCTAssertEqual(sockets.count, 1)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        for attempt in 0..<6 {
            sockets[attempt].emitStatus(.failed("network dropped \(attempt)"))
            for _ in 0..<80 where sockets.count < attempt + 2 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(sockets.count, attempt + 2)
            XCTAssertEqual(sockets[attempt + 1].connectedSessionIDs, [running.id])
        }
        if case .failed = store.webSocketStatus {
            XCTFail("前台 running session 不应因重连次数达到上限而停止重连")
        }
    }

    func testStaleWebSocketStatusDoesNotRetireCurrentReconnect() async throws {
        let project = makeProject(id: "proj_ws_stale_status")
        let running = makeSession(id: "sess_ws_stale_status", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        sockets[0].emitStatus(.failed("network dropped"))
        for _ in 0..<80 where sockets.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(sockets.count, 2)
        sockets[1].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        sockets[0].emitStatus(.disconnected)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.webSocketStatus, .connected)

        let sentAfterStaleStatus = await store.sendTurn(CodexAppServerTurnPayload(prompt: "after stale status"))
        XCTAssertTrue(sentAfterStaleStatus)
        XCTAssertTrue(sockets[0].sentTurns.isEmpty)
        XCTAssertEqual(sockets[1].sentTurns.count, 1)
    }

    func testConnectedRunningSessionIgnoresStaleHistoryRefreshBeforeNextSend() async throws {
        let project = makeProject(id: "proj_ws_stale_history")
        let running = makeSession(
            id: "sess_ws_stale_history",
            projectID: project.id,
            title: "长任务运行中",
            status: "running",
            source: "codex",
            activeTurnID: "turn-long-running"
        )
        let staleHistory = makeSession(
            id: running.id,
            projectID: project.id,
            title: running.title,
            status: "history",
            source: "codex",
            resumeID: running.id
        )
        let client = MutableSessionPageClient(projects: [project], page: SessionsPage(sessions: [running]))
        var sockets: [MockWebSocketClient] = []
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        XCTAssertEqual(sockets.count, 1)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        client.page = SessionsPage(sessions: [staleHistory])
        await store.refreshAll(autoAttach: false)

        XCTAssertEqual(store.selectedSession?.status, "running")
        XCTAssertEqual(store.selectedSession?.activeTurnID, "turn-long-running")

        let sent = await store.sendTurn(CodexAppServerTurnPayload(prompt: "继续当前长任务"))

        XCTAssertTrue(sent)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(sockets[0].sentTurns.count, 1)
        XCTAssertFalse(conversationStore.messages(for: running.id).contains { $0.content == "已继续这个历史会话。" })
    }

    func testWebSocketReconnectKeepsSubscriptionWhenSnapshotIsNoLongerRunning() async throws {
        let project = makeProject(id: "proj_ws_ended_reconnect")
        let running = makeSession(id: "sess_ws_ended_reconnect", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let ended = makeSession(id: running.id, projectID: project.id, title: "已结束", status: "history", source: "codex", resumeID: running.id)
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            sessionResponses: [
                running.id: try makeSessionResponse(session: ended, recentOutput: nil, lastSeq: nil)
            ],
            messagesResult: []
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        sockets[0].emitStatus(.failed("turn completed while reconnecting"))

        // 快照显示会话不再运行时不能一次性放弃重连：单次 thread/read 可能是上游刚恢复时的
        // idle 误读。订阅对历史会话同样有效，重连应继续并恢复事件通道。
        for _ in 0..<80 where sockets.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(store.selectedSession?.status, "history")
        sockets[1].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        XCTAssertNil(store.errorMessage)
    }

    func testWebSocketReconnectRefreshesSnapshotWithLatestEventWatermark() async throws {
        let project = makeProject(id: "proj_ws_snapshot_reconnect")
        let running = makeSession(id: "sess_ws_snapshot", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            sessionResponses: [
                running.id: try makeSessionResponse(session: running, recentOutput: nil, lastSeq: 9)
            ],
            historyPages: [
                running.id: HistoryMessagesPage(messages: [
                    CodexHistoryMessage(id: "rollout:9", role: "assistant", content: "重连前补拉消息", createdAt: Date(timeIntervalSince1970: 9))
                ])
            ]
        )
        var sockets: [MockWebSocketClient] = []
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        sockets[0].emitEvent(.assistantDelta(
            AgentDelta(text: "A", role: .assistant, kind: .message),
            AgentEventMetadata(seq: 9, sessionID: running.id, turnID: "turn_1", itemID: "item_1", messageID: nil, clientMessageID: nil, revision: 1, createdAt: nil)
        ))

        sockets[0].emitStatus(.failed("network dropped"))
        for _ in 0..<50 where sockets.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(client.requestedSessionIDs, [running.id])
        XCTAssertEqual(client.requestedSessionAfterSeqs, [9])
        XCTAssertEqual(sockets[1].connectedSessionIDs, [running.id])
        XCTAssertTrue(conversationStore.messages(for: running.id).contains { $0.content == "重连前补拉消息" })
    }

    func testWebSocketReconnectUsesHistorySnapshotSeqWatermark() async throws {
        let project = makeProject(id: "proj_ws_history_snapshot")
        let running = makeSession(id: "sess_ws_history_snapshot", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            sessionResponses: [
                running.id: try makeSessionResponse(session: running, recentOutput: nil, lastSeq: nil)
            ],
            historyPages: [
                running.id: HistoryMessagesPage(messages: [], snapshotSeq: 11)
            ]
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        sockets[0].emitStatus(.failed("network dropped"))
        for _ in 0..<50 where sockets.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(client.requestedSessionAfterSeqs, [11])
        XCTAssertEqual(sockets[1].connectedSessionIDs, [running.id])
    }

    func testReturningToSessionListCancelsQueuedWebSocketReconnect() async throws {
        let project = makeProject(id: "proj_ws_cancel")
        let running = makeSession(id: "sess_ws_cancel", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectDelayNanoseconds: { _ in 120_000_000 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        sockets[0].emitStatus(.failed("network dropped"))
        try await waitForWebSocketStatus(.connecting, store: store)

        store.returnToSessionList()
        try await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(store.webSocketStatus, .disconnected)
    }

    func testRunningSessionAloneDoesNotShowForegroundActivity() async {
        let project = makeProject(id: "proj_1")
        let running = makeSession(id: "sess_running", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.selectedSessionID = running.id

        XCTAssertNil(store.selectedForegroundActivity)
    }

    func testRuntimeActivityTracksTurnEventsAndClearsOnCompletion() async throws {
        let project = makeProject(id: "proj_runtime_activity")
        let running = makeSession(id: "sess_runtime_activity", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        XCTAssertNil(store.selectedRuntimeActivitySnapshot)

        sockets[0].emitEvent(.turnStarted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn-runtime",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))

        let started = try await waitForRuntimeActivity(in: store, sessionID: running.id)
        XCTAssertLessThanOrEqual(started.turnStartedAt, started.lastActivityAt)
        try await waitForSelectedActiveTurnID("turn-runtime", store: store)

        try await Task.sleep(nanoseconds: 120_000_000)
        sockets[0].emitEvent(.logDelta(
            LogDelta(text: "still working\n", stream: "stdout"),
            AgentEventMetadata(
                seq: 2,
                sessionID: running.id,
                turnID: "turn-runtime",
                itemID: "cmd-1",
                messageID: nil,
                clientMessageID: nil,
                revision: nil,
                createdAt: nil
            )
        ))

        let updated = try await waitForRuntimeActivity(in: store, sessionID: running.id) { snapshot in
            snapshot.lastActivityAt > started.lastActivityAt
        }
        XCTAssertEqual(updated.turnStartedAt, started.turnStartedAt)

        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 3,
            sessionID: running.id,
            turnID: "turn-runtime",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))

        try await waitForRuntimeActivityCleared(in: store, sessionID: running.id)
        try await waitForSelectedActiveTurnID(nil, store: store)
    }

    func testSendingPromptCreatesWaitingForegroundActivity() async throws {
        let project = makeProject(id: "proj_1")
        let created = makeSession(id: "sess_created", projectID: project.id, title: "新会话", status: "running", source: "codex")
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

    func testCreatingSessionForwardsStructuredPayloadAndOptions() async throws {
        let project = makeProject(id: "proj_rich_create")
        let created = makeSession(id: "sess_rich_create", projectID: project.id, title: "Rich Create", status: "running", source: "codex")
        let client = DelayedCreateSessionClient(projects: [project], sessions: [])
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        var options = CodexAppServerTurnOptions.default
        options.model = "gpt-5-codex"
        options.serviceTier = "priority"
        options.approvalPolicy = .onFailure
        let payload = CodexAppServerTurnPayload(input: [
            .text("分析截图"),
            .image(url: "data:image/png;base64,AA==", detail: .high),
            .skill(name: "review", path: project.path)
        ], options: options)

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let sendTask = Task { await store.sendTurn(payload) }
        await client.waitForCreateRequestCount(1)

        let sent = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(sent.prompt, payload.previewText)
        XCTAssertEqual(sent.input, payload.input)
        XCTAssertEqual(sent.turnOptions.model, "gpt-5-codex")
        XCTAssertEqual(sent.turnOptions.serviceTier, "priority")
        XCTAssertEqual(sent.turnOptions.approvalPolicy, .onFailure)

        client.resolveCreate(with: .success(try makeCreateSessionResponse(session: created)))
        let accepted = await sendTask.value
        XCTAssertTrue(accepted)
        let message = try XCTUnwrap(conversationStore.messages(for: created.id).first)
        XCTAssertTrue(payloadContainsInlineImage(message.turnPayload))
        XCTAssertTrue(payloadContainsSkill(message.turnPayload, name: "review"))
        XCTAssertEqual(message.turnPayload?.options, options)
    }

    func testStartGoalTurnOnRunningSessionSetsGoalThenSendsPayload() async throws {
        let project = makeProject(id: "proj_goal_running")
        let running = makeSession(id: "sess_goal_running", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let payload = CodexAppServerTurnPayload(prompt: "修复 iPad 目标入口")
        let accepted = await store.startGoalTurn(payload: payload, objective: "  修复 iPad 目标入口  ")

        XCTAssertTrue(accepted)
        XCTAssertEqual(client.requestedThreadGoalSets, [
            RequestedThreadGoalSet(
                threadID: running.id,
                objective: "修复 iPad 目标入口",
                status: .active,
                tokenBudget: nil
            )
        ])
        XCTAssertEqual(sockets[0].sentTurns.count, 1)
        XCTAssertEqual(sockets[0].sentTurns.first?.payload.textPrompt, "修复 iPad 目标入口")
    }

    func testTurnCompletionFinishesActiveGoalAndIgnoresStaleActiveGoalRefresh() async throws {
        let project = makeProject(id: "proj_goal_complete")
        let goal = ThreadGoal(
            threadID: "thread_goal_complete",
            objective: "修复完成后仍显示运行中",
            status: .active,
            tokenBudget: 80_000,
            tokensUsed: 12_000,
            timeUsedSeconds: 420
        )
        let running = AgentSession(
            id: "sess_goal_complete",
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: "目标会话",
            status: "running",
            source: "codex",
            resumeID: goal.threadID,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            activeTurnID: "turn-goal-complete",
            goal: goal
        )
        let reactivatedGoal = ThreadGoal(
            threadID: goal.threadID,
            objective: goal.objective,
            status: .active,
            tokenBudget: goal.tokenBudget,
            tokensUsed: goal.tokensUsed,
            timeUsedSeconds: goal.timeUsedSeconds
        )
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            threadGoalSetResults: [
                running.id: .success(reactivatedGoal)
            ]
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn-goal-complete",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))

        try await waitForSelectedThreadGoalStatus(.complete, store: store)
        try await waitForSelectedSessionStatus(SessionStatus.completed.rawValue, store: store)
        try await waitForSelectedActiveTurnID(nil, store: store)
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.completed.rawValue)
        XCTAssertNil(store.selectedSession?.activeTurnID)

        sockets[0].emitEvent(.goalUpdated(goal, AgentEventMetadata(
            seq: 2,
            sessionID: running.id,
            turnID: nil,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        sockets[0].emitEvent(.session(running))

        try await waitForSelectedThreadGoalStatus(.complete, store: store)

        await store.updateSelectedThreadGoalStatus(.active)

        try await waitForSelectedThreadGoalStatus(.active, store: store)
        XCTAssertEqual(client.requestedThreadGoalSets.last, RequestedThreadGoalSet(
            threadID: running.id,
            objective: nil,
            status: .active,
            tokenBudget: nil
        ))
    }

    func testSelectedThreadGoalStaysScopedToSelectedThread() async throws {
        let project = makeProject(id: "proj_goal_scope")
        let goal = ThreadGoal(
            threadID: "thread-with-goal",
            objective: "只属于对话一的目标",
            status: .active,
            tokenBudget: 50_000
        )
        let goalSession = AgentSession(
            id: "codex_thread_with_goal",
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: "对话一",
            status: "closed",
            source: "codex",
            resumeID: goal.threadID,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            goal: goal
        )
        let staleContext = SessionContextSnapshot(
            sessionID: "thread-without-goal",
            threadID: "thread-without-goal",
            goal: goal,
            updatedAt: Date(timeIntervalSince1970: 3)
        )
        let plainSession = AgentSession(
            id: "thread-without-goal",
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: "对话二",
            status: "closed",
            source: "codex",
            resumeID: "thread-without-goal",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 3),
            context: staleContext
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [goalSession, plainSession], messagesResult: [])
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)

        await store.selectSession(goalSession)
        XCTAssertEqual(store.selectedThreadGoal?.threadID, goal.threadID)
        XCTAssertEqual(store.selectedThreadGoal?.objective, "只属于对话一的目标")

        await store.selectSession(plainSession)
        XCTAssertNil(store.selectedThreadGoal)
        XCTAssertNil(store.selectedSession?.goal)
    }

    func testStartGoalTurnForNewSessionCarriesInitialGoalObjective() async throws {
        let project = makeProject(id: "proj_goal_create")
        let created = makeSession(id: "sess_goal_create", projectID: project.id, title: "目标任务", status: "running", source: "codex")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            createSessionResponse: try makeCreateSessionResponse(session: created),
            modelOptions: [
                CodexAppServerModelOption(id: "gpt-goal-default", title: "Goal Default", provider: "openai", isDefault: true)
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let payload = CodexAppServerTurnPayload(prompt: "实现 iPad 目标任务")
        let accepted = await store.startGoalTurn(payload: payload, objective: "  实现 iPad 目标任务  ")

        XCTAssertTrue(accepted)
        let createPayload = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(createPayload.prompt, "实现 iPad 目标任务")
        XCTAssertEqual(createPayload.initialGoalObjective, "实现 iPad 目标任务")
        XCTAssertEqual(createPayload.input, payload.input)
        XCTAssertEqual(createPayload.turnOptions.model, "gpt-goal-default")
        XCTAssertEqual(createPayload.turnOptions.collaborationMode, .default)
        XCTAssertEqual(store.selectedSessionID, created.id)
    }

    func testRefreshAppServerModelOptionsCachesDynamicList() async throws {
        let options = [
            CodexAppServerModelOption(id: "gpt-5.1-codex", title: "GPT-5.1 Codex", provider: "openai", isDefault: true),
            CodexAppServerModelOption(id: "gpt-5-codex", title: "GPT-5 Codex", provider: "openai")
        ]
        let client = MockSessionStoreClient(projects: [], sessions: [], modelOptions: options)
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAppServerModelOptions(force: true)

        XCTAssertEqual(store.appServerModelOptions.map(\.model), ["gpt-5.1-codex", "gpt-5-codex"])
        XCTAssertEqual(client.modelOptionsCallCount, 1)
    }

    func testNewSessionResolvesMissingModelFromAppServerDefaultBeforeCreate() async throws {
        let project = makeProject(id: "proj_resolve_model_create")
        let created = makeSession(id: "sess_resolve_model_create", projectID: project.id, title: "模型解析", status: "running", source: "codex")
        let options = [
            CodexAppServerModelOption(id: "gpt-dynamic-default", title: "Dynamic Default", provider: "openai", isDefault: true),
            CodexAppServerModelOption(id: "gpt-other", title: "Other", provider: "openai")
        ]
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            createSessionResponse: try makeCreateSessionResponse(session: created),
            modelOptions: options
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let accepted = await store.sendTurn(CodexAppServerTurnPayload(prompt: "检查默认模型"))

        XCTAssertTrue(accepted)
        let createPayload = try XCTUnwrap(client.createPayloads.first)
        // app-server turn/start 必填 model；iPad 发送前必须用 model/list 的默认项补齐，而不是省略。
        XCTAssertEqual(createPayload.turnOptions.model, "gpt-dynamic-default")
        XCTAssertEqual(createPayload.turnOptions.modelProvider, "openai")
        XCTAssertNil(createPayload.turnOptions.runtimeProvider)
        XCTAssertEqual(createPayload.turnOptions.collaborationMode, .default)
        XCTAssertEqual(client.modelOptionsCallCount, 1)
    }

    func testDefaultModelResolutionCarriesRuntimeProviderBeforeCreate() async throws {
        let project = makeProject(id: "proj_default_runtime_create")
        let created = makeSession(id: "sess_default_runtime_create", projectID: project.id, title: "默认 Claude 模型", status: "running", source: "claude", runtimeProvider: "claude")
        let options = [
            CodexAppServerModelOption(id: "claude-sonnet", title: "Claude Sonnet", provider: "anthropic", runtimeProvider: "claude", isDefault: true)
        ]
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            createSessionResponse: try makeCreateSessionResponse(session: created),
            modelOptions: options
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let accepted = await store.sendTurn(CodexAppServerTurnPayload(prompt: "检查 Claude 默认模型"))

        XCTAssertTrue(accepted)
        let createPayload = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(createPayload.turnOptions.runtimeProvider, "claude")
        XCTAssertEqual(createPayload.turnOptions.model, "claude-sonnet")
        XCTAssertEqual(createPayload.turnOptions.modelProvider, "anthropic")
        XCTAssertEqual(createPayload.turnOptions.sandboxMode, .workspaceWrite)
        XCTAssertEqual(createPayload.turnOptions.networkAccess, false)
    }

    func testExplicitModelBypassesModelListResolutionBeforeCreate() async throws {
        let project = makeProject(id: "proj_explicit_model_create")
        let created = makeSession(id: "sess_explicit_model_create", projectID: project.id, title: "显式模型", status: "running", source: "codex")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            createSessionResponse: try makeCreateSessionResponse(session: created),
            modelOptions: [
                CodexAppServerModelOption(id: "gpt-should-not-load", title: "Should Not Load", provider: "openai", isDefault: true)
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        var options = CodexAppServerTurnOptions.default
        options.model = "gpt-user-selected"
        options.modelProvider = "custom-provider"
        let accepted = await store.sendTurn(CodexAppServerTurnPayload(prompt: "使用显式模型", options: options))

        XCTAssertTrue(accepted)
        let createPayload = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(createPayload.turnOptions.model, "gpt-user-selected")
        XCTAssertEqual(createPayload.turnOptions.modelProvider, "custom-provider")
        XCTAssertEqual(client.modelOptionsCallCount, 0)
    }

    func testCodexHistorySessionIgnoresStaleClaudeModelSelectionBeforeResume() async throws {
        let project = makeProject(id: "proj_codex_history_runtime_lock")
        let history = makeSession(
            id: "sess_codex_history_runtime_lock",
            projectID: project.id,
            title: "Codex 历史会话",
            status: "closed",
            source: "codex",
            resumeID: "thread-codex-history-runtime-lock"
        )
        let resumed = makeSession(
            id: "sess_codex_history_runtime_lock_resumed",
            projectID: project.id,
            title: "Codex 历史会话",
            status: "running",
            source: "codex",
            resumeID: "thread-codex-history-runtime-lock"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            createSessionResponse: try makeCreateSessionResponse(session: resumed),
            messagesResult: [],
            modelOptions: [
                CodexAppServerModelOption(id: "gpt-codex-default", title: "Codex Default", provider: "openai", runtimeProvider: "codex", isDefault: true),
                CodexAppServerModelOption(id: "sonnet", title: "Claude Sonnet 5", provider: "anthropic", runtimeProvider: "claude", isDefault: true)
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)
        var options = CodexAppServerTurnOptions.default
        options.runtimeProvider = "claude"
        options.model = "opus"
        options.modelProvider = "anthropic"
        let accepted = await store.sendTurn(CodexAppServerTurnPayload(prompt: "继续 Codex 历史会话", options: options))

        XCTAssertTrue(accepted)
        let createPayload: CreateSessionRequest = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(createPayload.resumeID, "thread-codex-history-runtime-lock")
        XCTAssertNil(createPayload.turnOptions.runtimeProvider)
        XCTAssertEqual(createPayload.turnOptions.model, "gpt-codex-default")
        XCTAssertEqual(createPayload.turnOptions.modelProvider, "openai")
        XCTAssertEqual(client.modelOptionsCallCount, 1)
    }

    func testClaudeHistorySessionIgnoresStaleCodexModelSelectionBeforeResume() async throws {
        let project = makeProject(id: "proj_claude_history_runtime_lock")
        let history = makeSession(
            id: "sess_claude_history_runtime_lock",
            projectID: project.id,
            title: "Claude 历史会话",
            status: "closed",
            source: "claude",
            runtimeProvider: "claude",
            resumeID: "thread-claude-history-runtime-lock"
        )
        let resumed = makeSession(
            id: "sess_claude_history_runtime_lock_resumed",
            projectID: project.id,
            title: "Claude 历史会话",
            status: "running",
            source: "claude",
            runtimeProvider: "claude",
            resumeID: "thread-claude-history-runtime-lock"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            createSessionResponse: try makeCreateSessionResponse(session: resumed),
            messagesResult: [],
            modelOptions: [
                CodexAppServerModelOption(id: "gpt-codex-default", title: "Codex Default", provider: "openai", runtimeProvider: "codex", isDefault: true),
                CodexAppServerModelOption(id: "sonnet", title: "Claude Sonnet 5", provider: "anthropic", runtimeProvider: "claude", isDefault: true)
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)
        var options = CodexAppServerTurnOptions.default
        options.runtimeProvider = nil
        options.model = "gpt-codex-default"
        options.modelProvider = "openai"
        let accepted = await store.sendTurn(CodexAppServerTurnPayload(prompt: "继续 Claude 历史会话", options: options))

        XCTAssertTrue(accepted)
        let createPayload: CreateSessionRequest = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(createPayload.resumeID, "thread-claude-history-runtime-lock")
        XCTAssertEqual(createPayload.turnOptions.runtimeProvider, "claude")
        XCTAssertEqual(createPayload.turnOptions.model, "sonnet")
        XCTAssertEqual(createPayload.turnOptions.modelProvider, "anthropic")
        XCTAssertEqual(createPayload.turnOptions.sandboxMode, .workspaceWrite)
        XCTAssertEqual(client.modelOptionsCallCount, 1)
    }

    func testExplicitClaudeModelClampsDangerFullAccessBeforeCreate() async throws {
        let project = makeProject(id: "proj_explicit_claude_clamp")
        let created = makeSession(id: "sess_explicit_claude_clamp", projectID: project.id, title: "Claude Clamp", status: "running", source: "claude", runtimeProvider: "claude")
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
        var options = CodexAppServerTurnOptions.default
        options.runtimeProvider = "claude"
        options.model = "claude-sonnet"
        options.modelProvider = "anthropic"
        options.sandboxMode = .dangerFullAccess
        options.networkAccess = true
        let accepted = await store.sendTurn(CodexAppServerTurnPayload(prompt: "使用 Claude", options: options))

        XCTAssertTrue(accepted)
        let createPayload = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(createPayload.turnOptions.runtimeProvider, "claude")
        XCTAssertEqual(createPayload.turnOptions.model, "claude-sonnet")
        XCTAssertEqual(createPayload.turnOptions.sandboxMode, .workspaceWrite)
        XCTAssertEqual(createPayload.turnOptions.networkAccess, false)
        XCTAssertEqual(client.modelOptionsCallCount, 0)
    }

    func testModelListFailureFallsBackToBuiltInModelBeforeCreate() async throws {
        let project = makeProject(id: "proj_model_fallback_create")
        let created = makeSession(id: "sess_model_fallback_create", projectID: project.id, title: "模型兜底", status: "running", source: "codex")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            createSessionResponse: try makeCreateSessionResponse(session: created),
            modelOptionsError: MockError.timeout
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let accepted = await store.sendTurn(CodexAppServerTurnPayload(prompt: "模型列表失败也要能发"))

        XCTAssertTrue(accepted)
        let createPayload = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(createPayload.turnOptions.model, "gpt-5.5")
        XCTAssertNil(createPayload.turnOptions.modelProvider)
        XCTAssertEqual(client.modelOptionsCallCount, 1)
    }

    func testEmptyPayloadDoesNotRefreshModelOptions() async throws {
        let project = makeProject(id: "proj_empty_payload_model")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            modelOptions: [
                CodexAppServerModelOption(id: "gpt-unused", title: "Unused", provider: "openai", isDefault: true)
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let accepted = await store.sendTurn(CodexAppServerTurnPayload(prompt: "   "))

        XCTAssertFalse(accepted)
        XCTAssertEqual(client.modelOptionsCallCount, 0)
        XCTAssertTrue(client.createPayloads.isEmpty)
    }

    func testRunningQueuedTurnResolvesMissingModelButGuidedFollowUpDoesNot() async throws {
        let project = makeProject(id: "proj_running_resolve_model")
        let running = makeSession(
            id: "sess_running_resolve_model",
            projectID: project.id,
            title: "运行中模型解析",
            status: "running",
            source: "codex",
            activeTurnID: "turn_active_model"
        )
        let options = [
            CodexAppServerModelOption(id: "gpt-running-default", title: "Running Default", provider: "openai", isDefault: true)
        ]
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [], modelOptions: options)
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let queued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "排队新任务"))
        let guided = await store.sendTurn(CodexAppServerTurnPayload(prompt: "继续当前回复"), runningDelivery: .guided)

        XCTAssertTrue(queued)
        XCTAssertTrue(guided)
        let queuedPayload = try XCTUnwrap(sockets[0].sentTurns.first?.payload)
        XCTAssertEqual(queuedPayload.options.model, "gpt-running-default")
        XCTAssertEqual(queuedPayload.options.modelProvider, "openai")
        let guidedPayload = try XCTUnwrap(sockets[0].sentGuidance.first?.payload)
        // guided follow-up 走 turn/steer，不启动新 turn/start，因此不补 model、不携带 collaborationMode 参数。
        XCTAssertNil(guidedPayload.options.model)
        XCTAssertEqual(client.modelOptionsCallCount, 1)
    }

    func testNewSessionPromptLocalEchoConfirmsWithoutDuplicateWhenCreateReturns() async throws {
        let project = makeProject(id: "proj_local_echo")
        let created = makeSession(id: "sess_created_echo", projectID: project.id, title: "新会话", status: "running", source: "codex")
        let client = DelayedCreateSessionClient(projects: [project], sessions: [])
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let sendTask = Task { await store.sendPrompt("帮我检查项目") }
        await client.waitForCreateRequestCount(1)

        let optimisticSessionID = try XCTUnwrap(store.selectedSessionID)
        XCTAssertTrue(optimisticSessionID.hasPrefix("local:"))
        XCTAssertEqual(conversationStore.messages(for: optimisticSessionID).map(\.content), ["帮我检查项目"])
        XCTAssertEqual(conversationStore.messages(for: optimisticSessionID).first?.sendStatus, .sending)

        let clientMessageID = try XCTUnwrap(client.createPayloads.first?.clientMessageID)
        let firstMessageJSON = """
        "first_message": {
          "id": "client:\(clientMessageID)",
          "session_id": "\(created.id)",
          "client_message_id": "\(clientMessageID)",
          "role": "user",
          "kind": "message",
          "content": "帮我检查项目",
          "revision": 1,
          "send_status": "confirmed"
        }
        """
        client.resolveCreate(with: .success(try makeCreateSessionResponse(session: created, firstMessageJSON: firstMessageJSON)))

        let sendSucceeded = await sendTask.value
        XCTAssertTrue(sendSucceeded)
        XCTAssertEqual(store.selectedSessionID, created.id)
        XCTAssertFalse(store.sessions.contains { $0.id == optimisticSessionID })
        XCTAssertTrue(conversationStore.messages(for: optimisticSessionID).isEmpty)
        let messages = conversationStore.messages(for: created.id)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.clientMessageID, clientMessageID)
        XCTAssertEqual(messages.first?.sendStatus, .confirmed)
        XCTAssertEqual(messages.first?.stableID, "client:\(clientMessageID)")
    }

    func testNewSessionPromptFailureKeepsFailedLocalEcho() async throws {
        let project = makeProject(id: "proj_local_echo_fail")
        let client = DelayedCreateSessionClient(projects: [project], sessions: [])
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let sendTask = Task { await store.sendPrompt("失败也要留在时间线") }
        await client.waitForCreateRequestCount(1)

        let optimisticSessionID = try XCTUnwrap(store.selectedSessionID)
        XCTAssertEqual(conversationStore.messages(for: optimisticSessionID).first?.sendStatus, .sending)

        client.resolveCreate(with: .failure(MockError.unimplemented))

        let sendSucceeded = await sendTask.value
        XCTAssertFalse(sendSucceeded)
        XCTAssertEqual(store.selectedSessionID, optimisticSessionID)
        XCTAssertEqual(store.selectedSession?.status, "failed")
        XCTAssertEqual(conversationStore.messages(for: optimisticSessionID).first?.content, "失败也要留在时间线")
        XCTAssertEqual(conversationStore.messages(for: optimisticSessionID).first?.sendStatus, .failed)
    }

    func testNewSessionRichPayloadFailureKeepsInlineImageForRetry() async throws {
        let project = makeProject(id: "proj_rich_echo_fail")
        let client = DelayedCreateSessionClient(projects: [project], sessions: [])
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        let payload = CodexAppServerTurnPayload(input: [
            .text("失败后重试图片"),
            .image(url: "data:image/png;base64,AA==", detail: .high),
            .mention(name: "README", path: project.path)
        ])

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let sendTask = Task { await store.sendTurn(payload) }
        await client.waitForCreateRequestCount(1)

        client.resolveCreate(with: .failure(MockError.unimplemented), at: 0)
        let sendSucceeded = await sendTask.value

        XCTAssertFalse(sendSucceeded)
        let optimisticSessionID = try XCTUnwrap(store.selectedSessionID)
        let failedMessage = try XCTUnwrap(conversationStore.messages(for: optimisticSessionID).first)
        XCTAssertEqual(failedMessage.sendStatus, .failed)
        XCTAssertTrue(payloadContainsInlineImage(failedMessage.turnPayload))
        XCTAssertEqual(failedMessage.turnPayload?.input, payload.input)
        XCTAssertEqual(failedMessage.turnPayload?.options.model, "gpt-5.5")

        let retryTask = Task { await store.retryFailedUserMessage(failedMessage) }
        await client.waitForCreateRequestCount(2)
        XCTAssertEqual(client.createPayloads[1].input, payload.input)
        XCTAssertEqual(client.createPayloads[1].turnOptions.model, "gpt-5.5")
        XCTAssertTrue(client.createPayloads[1].input.contains { item in
            if case .image(let url, _) = item {
                return url == "data:image/png;base64,AA=="
            }
            return false
        })
        client.resolveCreate(with: .failure(MockError.unimplemented), at: 1)
        let retrySucceeded = await retryTask.value
        XCTAssertFalse(retrySucceeded)
    }

    func testFailedRunningMessageRetryReusesClientMessageID() async throws {
        let project = makeProject(id: "proj_retry")
        let running = makeSession(id: "sess_retry", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        XCTAssertEqual(sockets.count, 1)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        conversationStore.appendLocalUser("请重试", sessionID: running.id, clientMessageID: "client-retry", sendStatus: .failed)
        let failedMessage = try XCTUnwrap(conversationStore.messages(for: running.id).first {
            $0.clientMessageID == "client-retry"
        })

        let retried = await store.retryFailedUserMessage(failedMessage)

        XCTAssertTrue(retried)
        XCTAssertTrue(sockets[0].sentInputs.isEmpty)
        XCTAssertEqual(sockets[0].sentTurns.count, 1)
        XCTAssertEqual(sockets[0].sentTurns.first?.payload.textPrompt, "请重试")
        XCTAssertEqual(sockets[0].sentTurns.first?.clientMessageID, "client-retry")
        let messages = conversationStore.messages(for: running.id)
        let retriedMessages = messages.filter { $0.clientMessageID == "client-retry" }
        XCTAssertEqual(retriedMessages.count, 1)
        XCTAssertEqual(retriedMessages.first?.sendStatus, .sending)
        sockets[0].onSendAccepted?("client-retry")
        let acceptedMessages = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            messages.contains { $0.clientMessageID == "client-retry" && $0.sendStatus == .sent }
        }
        XCTAssertEqual(acceptedMessages.first { $0.clientMessageID == "client-retry" }?.sendStatus, .sent)
    }

    func testFailedRunningMessageRetryDoesNotResumeWhenWebSocketIsConnecting() async throws {
        let project = makeProject(id: "proj_retry_connecting_guard")
        let running = makeSession(id: "sess_retry_connecting_guard", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        try await waitForWebSocketStatus(.connecting, store: store)
        conversationStore.appendLocalUser("重试不要新建会话", sessionID: running.id, clientMessageID: "client-retry-connecting", sendStatus: .failed)
        let failedMessage = try XCTUnwrap(conversationStore.messages(for: running.id).first {
            $0.clientMessageID == "client-retry-connecting"
        })

        let retried = await store.retryFailedUserMessage(failedMessage)

        XCTAssertFalse(retried)
        XCTAssertTrue(sockets[0].sentTurns.isEmpty)
        XCTAssertTrue(client.createPayloads.isEmpty)
        XCTAssertEqual(conversationStore.messages(for: running.id).first?.sendStatus, .failed)
    }

    func testRetryFailedUserMessagePreservesStructuredTurnPayload() async throws {
        let project = makeProject(id: "proj_retry_payload")
        let running = makeSession(id: "sess_retry_payload", projectID: project.id, title: "Retry Payload", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let payload = CodexAppServerTurnPayload(input: [
            .text("看下这张图"),
            .image(url: "data:image/png;base64,AA==", detail: .high),
            .mention(name: "README", path: project.path)
        ])
        conversationStore.appendLocalUser(
            payload.previewText,
            sessionID: running.id,
            clientMessageID: "client-rich-retry",
            sendStatus: .failed,
            turnPayload: payload
        )

        let retried = await store.retryFailedUserMessage(try XCTUnwrap(conversationStore.messages(for: running.id).first))

        XCTAssertTrue(retried)
        let sent = try XCTUnwrap(sockets[0].sentTurns.first)
        XCTAssertEqual(sent.clientMessageID, "client-rich-retry")
        XCTAssertEqual(sent.payload.input, payload.input)
        XCTAssertEqual(sent.payload.options.model, "gpt-5.5")
    }

    func testRunningSendKeepsInlineImagePayloadAfterAcceptedForPreview() async throws {
        let project = makeProject(id: "proj_keep_payload")
        let running = makeSession(id: "sess_keep_payload", projectID: project.id, title: "Keep Payload", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let payload = CodexAppServerTurnPayload(input: [
            .text("看下这张图"),
            .image(url: "data:image/png;base64,AA==", detail: .high),
            .image(url: "https://example.test/diagram.png", detail: .low),
            .mention(name: "README", path: project.path)
        ])
        let sent = await store.sendTurn(payload)

        XCTAssertTrue(sent)
        XCTAssertEqual(sockets[0].sentTurns.count, 1)
        let localEcho = try XCTUnwrap(conversationStore.messages(for: running.id).first { $0.clientMessageID != nil })
        let clientMessageID = try XCTUnwrap(localEcho.clientMessageID)
        XCTAssertTrue(payloadContainsInlineImage(localEcho.turnPayload))
        XCTAssertEqual(localEcho.turnPayload?.input, payload.input)
        XCTAssertEqual(localEcho.turnPayload?.options.model, "gpt-5.5")

        sockets[0].onSendAccepted?(clientMessageID)
        let acceptedMessages = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            guard let message = messages.first(where: { $0.clientMessageID == clientMessageID }) else {
                return false
            }
            return message.sendStatus == .sent
        }
        let accepted = try XCTUnwrap(acceptedMessages.first { $0.clientMessageID == clientMessageID })
        XCTAssertTrue(payloadContainsInlineImage(accepted.turnPayload))
        XCTAssertTrue(payloadContainsImageURL(accepted.turnPayload, url: "https://example.test/diagram.png"))
        XCTAssertTrue(payloadContainsMention(accepted.turnPayload, name: "README"))
        XCTAssertEqual(accepted.turnPayload?.textPrompt, "看下这张图")
    }

    func testRunningTurnLifecycleKeepsEchoAndFinalAssistantStable() async throws {
        let project = makeProject(id: "proj_turn_lifecycle")
        let running = makeSession(id: "sess_turn_lifecycle", projectID: project.id, title: "Lifecycle", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: {
                MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
            },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let sent = await store.sendTurn(CodexAppServerTurnPayload(prompt: "从输入框提交"))
        XCTAssertTrue(sent)
        let localEcho = try XCTUnwrap(conversationStore.messages(for: running.id).first { $0.role == .user })
        let clientMessageID = try XCTUnwrap(localEcho.clientMessageID)
        XCTAssertEqual(localEcho.sendStatus, .sending)
        XCTAssertEqual(sockets[0].sentTurns.first?.clientMessageID, clientMessageID)

        sockets[0].onSendAccepted?(clientMessageID)
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            messages.contains { $0.clientMessageID == clientMessageID && $0.sendStatus == .sent }
        }

        sockets[0].emitEvent(.turnStarted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn-lifecycle",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSelectedActiveTurnID("turn-lifecycle", store: store)

        sockets[0].emitEvent(.messageCompleted(
            AgentMessage(
                id: "client:\(clientMessageID)",
                sessionID: running.id,
                clientMessageID: clientMessageID,
                turnID: "turn-lifecycle",
                itemID: "user-lifecycle",
                role: .user,
                content: "从输入框提交",
                revision: 2,
                sendStatus: .confirmed
            ),
            AgentEventMetadata(
                seq: 2,
                sessionID: running.id,
                turnID: "turn-lifecycle",
                itemID: "user-lifecycle",
                messageID: "client:\(clientMessageID)",
                clientMessageID: clientMessageID,
                revision: 2,
                createdAt: nil
            )
        ))
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            messages.filter { $0.clientMessageID == clientMessageID }.count == 1 &&
                messages.contains { $0.clientMessageID == clientMessageID && $0.sendStatus == .confirmed }
        }

        // 已确认的用户 echo 不能被后到 accepted/failure callback 降级。
        sockets[0].onSendAccepted?(clientMessageID)
        sockets[0].onSendFailure?(clientMessageID, "late failure")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(
            conversationStore.messages(for: running.id).first { $0.clientMessageID == clientMessageID }?.sendStatus,
            .confirmed
        )

        let assistantMetadata = AgentEventMetadata(
            seq: 3,
            sessionID: running.id,
            turnID: "turn-lifecycle",
            itemID: "assistant-lifecycle",
            messageID: "assistant-final",
            clientMessageID: nil,
            revision: 7,
            createdAt: nil
        )
        sockets[0].emitEvent(.assistantDelta(
            AgentDelta(text: "阶段性片段", role: .assistant, kind: .message),
            assistantMetadata
        ))
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            messages.contains { $0.stableID == "assistant-final" && $0.content == "阶段性片段" && $0.sendStatus == .sending }
        }

        sockets[0].emitEvent(.messageCompleted(
            AgentMessage(
                id: "assistant-final",
                sessionID: running.id,
                turnID: "turn-lifecycle",
                itemID: "assistant-lifecycle",
                role: .assistant,
                content: "最终完整回答",
                revision: 7,
                sendStatus: .confirmed
            ),
            AgentEventMetadata(
                seq: 4,
                sessionID: running.id,
                turnID: "turn-lifecycle",
                itemID: "assistant-lifecycle",
                messageID: "assistant-final",
                clientMessageID: nil,
                revision: 7,
                createdAt: nil
            )
        ))
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            messages.filter { $0.stableID == "assistant-final" }.count == 1 &&
                messages.contains { $0.stableID == "assistant-final" && $0.content == "最终完整回答" && $0.sendStatus == .confirmed }
        }

        sockets[0].emitEvent(.assistantDelta(
            AgentDelta(text: "迟到增量", role: .assistant, kind: .message),
            AgentEventMetadata(
                seq: 5,
                sessionID: running.id,
                turnID: "turn-lifecycle",
                itemID: "assistant-lifecycle",
                messageID: "assistant-final",
                clientMessageID: nil,
                revision: 8,
                createdAt: nil
            )
        ))
        try await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertEqual(
            conversationStore.messages(for: running.id).first { $0.stableID == "assistant-final" }?.content,
            "最终完整回答"
        )
        XCTAssertEqual(
            conversationStore.messages(for: running.id).first { $0.stableID == "assistant-final" }?.sendStatus,
            .confirmed
        )

        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 6,
            sessionID: running.id,
            turnID: "turn-lifecycle",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSelectedActiveTurnID(nil, store: store)
        XCTAssertNil(store.selectedForegroundActivity)
    }

    func testRunningSessionGuidedDeliverySteersActiveTurn() async throws {
        let project = makeProject(id: "proj_ws_guided")
        let running = makeSession(
            id: "sess_ws_guided",
            projectID: project.id,
            title: "Running",
            status: "running",
            source: "codex",
            activeTurnID: "turn_active_guided"
        )
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let queued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "排队下一轮"))
        let guided = await store.sendTurn(CodexAppServerTurnPayload(prompt: "直接引导当前回复"), runningDelivery: .guided)

        XCTAssertTrue(queued)
        XCTAssertTrue(guided)
        XCTAssertEqual(sockets[0].sentTurns.count, 1)
        XCTAssertEqual(sockets[0].sentTurns.first?.payload.textPrompt, "排队下一轮")
        XCTAssertEqual(sockets[0].sentGuidance.count, 1)
        XCTAssertEqual(sockets[0].sentGuidance.first?.payload.textPrompt, "直接引导当前回复")
        XCTAssertEqual(sockets[0].sentGuidance.first?.expectedTurnID, "turn_active_guided")
    }

    func testRunningQueuedDeliveryWorksWithoutActiveTurnButGuidedDoesNot() async throws {
        let project = makeProject(id: "proj_ws_queued_without_active_turn")
        let running = makeSession(
            id: "sess_ws_queued_without_active_turn",
            projectID: project.id,
            title: "Running Without Active Turn",
            status: "running",
            source: "codex"
        )
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let queued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "排队下一轮"))
        let guided = await store.sendTurn(CodexAppServerTurnPayload(prompt: "尝试引导"), runningDelivery: .guided)

        XCTAssertTrue(queued)
        XCTAssertFalse(guided)
        XCTAssertEqual(sockets[0].sentTurns.count, 1)
        XCTAssertEqual(sockets[0].sentTurns.first?.payload.textPrompt, "排队下一轮")
        XCTAssertTrue(sockets[0].sentGuidance.isEmpty)
        XCTAssertEqual(store.errorMessage, "引导对话失败：当前会话没有活跃 turn")
    }

    func testSendCtrlCIgnoresRunningSessionWithoutActiveTurn() async throws {
        let project = makeProject(id: "proj_ctrl_c_without_active_turn")
        let running = makeSession(
            id: "sess_ctrl_c_without_active_turn",
            projectID: project.id,
            title: "No Active Turn",
            status: "running",
            source: "codex"
        )
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        store.sendCtrlC()

        XCTAssertEqual(sockets[0].sentCtrlCCount, 0)
        XCTAssertEqual(store.statusMessage, "当前没有可中断的活动回合")
        XCTAssertNil(store.errorMessage)
    }

    func testSendCtrlCSendsForConnectedActiveTurn() async throws {
        let project = makeProject(id: "proj_ctrl_c_active_turn")
        let running = makeSession(
            id: "sess_ctrl_c_active_turn",
            projectID: project.id,
            title: "Active Turn",
            status: "running",
            source: "codex",
            activeTurnID: "turn_ctrl_c"
        )
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        store.sendCtrlC()

        XCTAssertEqual(sockets[0].sentCtrlCCount, 1)
        XCTAssertNil(store.errorMessage)
    }

    func testRunningSessionGuidedDeliveryUsesTurnStartedActiveTurn() async throws {
        let project = makeProject(id: "proj_ws_guided_event")
        let running = makeSession(id: "sess_ws_guided_event", projectID: project.id, title: "Running", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        sockets[0].emitEvent(.turnStarted(AgentEventMetadata(
            seq: 1,
            sessionID: running.id,
            turnID: "turn_from_event",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSelectedActiveTurnID("turn_from_event", store: store)

        let guided = await store.sendTurn(CodexAppServerTurnPayload(prompt: "继续按这个方向"), runningDelivery: .guided)

        XCTAssertTrue(guided)
        XCTAssertEqual(sockets[0].sentGuidance.count, 1)
        XCTAssertEqual(sockets[0].sentGuidance.first?.payload.textPrompt, "继续按这个方向")
        XCTAssertEqual(sockets[0].sentGuidance.first?.expectedTurnID, "turn_from_event")
    }

    func testRunningSessionGuidedDeliveryBackfillsActiveTurnFromAssistantDelta() async throws {
        let project = makeProject(id: "proj_ws_guided_delta")
        let running = makeSession(id: "sess_ws_guided_delta", projectID: project.id, title: "Running", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        sockets[0].emitEvent(.assistantDelta(
            AgentDelta(text: "正在继续", role: .assistant, kind: .message),
            AgentEventMetadata(
                seq: 1,
                sessionID: running.id,
                turnID: "turn_from_delta",
                itemID: "assistant_delta",
                messageID: "assistant_delta",
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            )
        ))
        try await waitForSelectedActiveTurnID("turn_from_delta", store: store)

        let guided = await store.sendTurn(CodexAppServerTurnPayload(prompt: "沿着这个回复继续"), runningDelivery: .guided)

        XCTAssertTrue(guided)
        XCTAssertEqual(sockets[0].sentGuidance.count, 1)
        XCTAssertEqual(sockets[0].sentGuidance.first?.expectedTurnID, "turn_from_delta")
    }

    func testLateRuntimeEventDoesNotRestoreActiveTurnAfterCompletion() async throws {
        let project = makeProject(id: "proj_ws_late_turn")
        let running = makeSession(
            id: "sess_ws_late_turn",
            projectID: project.id,
            title: "Running",
            status: "running",
            source: "codex",
            activeTurnID: "turn_late"
        )
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        sockets[0].emitEvent(.turnCompleted(AgentEventMetadata(
            seq: 2,
            sessionID: running.id,
            turnID: "turn_late",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await waitForSelectedActiveTurnID(nil, store: store)
        try await waitForSelectedSessionStatus(SessionStatus.completed.rawValue, store: store)

        sockets[0].emitEvent(.assistantDelta(
            AgentDelta(text: "迟到片段", role: .assistant, kind: .message),
            AgentEventMetadata(
                seq: 3,
                sessionID: running.id,
                turnID: "turn_late",
                itemID: "assistant_late",
                messageID: "assistant_late",
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            )
        ))
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertNil(store.selectedSession?.activeTurnID)
        XCTAssertEqual(store.selectedSession?.status, SessionStatus.completed.rawValue)
    }

    func testTakeOverSelectedRunningSessionReconnectsWithoutContentReplay() async throws {
        // 接管时消息区已由 thread/read 快照兜底；完整回放会把 backlog 旧卡追加到
        // 已合并时间线后面（plan 在前、命令在后的事故路径），必须走状态级回放。
        let project = makeProject(id: "proj_takeover_replay")
        let running = makeSession(id: "sess_takeover_replay", projectID: project.id, title: "Running", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(running)
        XCTAssertEqual(sockets.count, 0, "未接管的运行会话应保持观察，不建立控制连接")

        store.takeOverSession(running)

        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(sockets[0].replayBufferedEventsByConnect, [false])
    }

    func testForegroundRefreshReattachDoesNotRequestContentReplay() async throws {
        // 前台恢复的 refreshAll 会重走 prepareSelectedSessionAfterRefresh；已加载会话的
        // loadHistoryIfNeeded 是 no-op，此时重连若要求完整回放，backlog 旧卡会破坏时间线顺序。
        let project = makeProject(id: "proj_foreground_replay")
        let running = makeSession(id: "sess_foreground_replay", projectID: project.id, title: "Running", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        XCTAssertEqual(sockets.count, 1)

        await store.refreshAll(autoAttach: true)

        XCTAssertGreaterThanOrEqual(sockets.count, 1)
        for socket in sockets {
            XCTAssertFalse(
                socket.replayBufferedEventsByConnect.contains(true),
                "前台恢复重连不应要求完整回放 backlog"
            )
        }
    }

    func testBufferedStateReplayKeepsCompletedContentEvents() {
        // thread/read 快照不含 commandExecution 过程 item；状态级回放必须保留 completed
        // 内容事件，否则离开期间完成的命令卡会永久丢失。流式 delta/日志仍不补播。
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { FakeCodexAppServerTransport() },
            configProvider: { makeDirectAppServerConfig(project: AgentProject(id: "proj_replay_filter", name: "Replay", path: "/tmp/replay-filter")) }
        )
        let metadata = AgentEventMetadata.empty
        let completed = AgentMessage(id: "m1", sessionID: "s1", role: .system, kind: .commandSummary, content: "命令：ls", revision: 1)

        XCTAssertTrue(runtime.shouldReplayBufferedStateEvent(.processItemCompleted(completed, nil, metadata)))
        XCTAssertTrue(runtime.shouldReplayBufferedStateEvent(.messageCompleted(completed, metadata)))
        XCTAssertTrue(runtime.shouldReplayBufferedStateEvent(.turnCompleted(metadata)))
        XCTAssertFalse(runtime.shouldReplayBufferedStateEvent(.assistantDelta(AgentDelta(text: "t", role: .assistant, kind: .message), metadata)))
        XCTAssertFalse(runtime.shouldReplayBufferedStateEvent(.logDelta(LogDelta(text: "l", stream: nil), metadata)))
    }

    func testRunningSessionSendWaitsForConnectedWebSocket() async throws {
        let project = makeProject(id: "proj_ws_connecting_guard")
        let running = makeSession(id: "sess_ws_connecting_guard", projectID: project.id, title: "连接中", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        try await waitForWebSocketStatus(.connecting, store: store)

        let sentWhileConnecting = await store.sendTurn(CodexAppServerTurnPayload(prompt: "不要在连接中发送"))

        XCTAssertFalse(sentWhileConnecting)
        XCTAssertTrue(sockets[0].sentTurns.isEmpty)
        XCTAssertTrue(conversationStore.messages(for: running.id).isEmpty)
        XCTAssertEqual(store.errorMessage, "WebSocket 正在连接，请稍后再发送")

        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        let sentAfterConnected = await store.sendTurn(CodexAppServerTurnPayload(prompt: "连接好后再发送"))

        XCTAssertTrue(sentAfterConnected)
        XCTAssertEqual(sockets[0].sentTurns.count, 1)
        XCTAssertEqual(sockets[0].sentTurns.first?.payload.textPrompt, "连接好后再发送")
    }

    func testWebSocketFailureMarksSendingUserMessagesFailedAndIgnoresStaleAccepted() async throws {
        let project = makeProject(id: "proj_ws_sending_failed")
        let running = makeSession(id: "sess_ws_sending_failed", projectID: project.id, title: "Sending Failed", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectDelayNanoseconds: { _ in 1_000_000_000 }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let acceptedSend = await store.sendTurn(CodexAppServerTurnPayload(prompt: "已经 accepted 的消息"))

        XCTAssertTrue(acceptedSend)
        let acceptedEcho = try XCTUnwrap(conversationStore.messages(for: running.id).first { $0.content == "已经 accepted 的消息" })
        let acceptedClientMessageID = try XCTUnwrap(acceptedEcho.clientMessageID)
        sockets[0].onSendAccepted?(acceptedClientMessageID)
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            messages.contains { $0.clientMessageID == acceptedClientMessageID && $0.sendStatus == .sent }
        }

        let sent = await store.sendTurn(CodexAppServerTurnPayload(prompt: "断线时不要卡在发送中"))

        XCTAssertTrue(sent)
        let localEcho = try XCTUnwrap(conversationStore.messages(for: running.id).first { $0.content == "断线时不要卡在发送中" })
        XCTAssertEqual(localEcho.sendStatus, .sending)

        sockets[0].emitStatus(.failed("network dropped"))
        let messages = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            messages.contains { $0.clientMessageID == localEcho.clientMessageID && $0.sendStatus == .failed }
        }

        XCTAssertEqual(messages.first(where: { $0.clientMessageID == acceptedClientMessageID })?.sendStatus, .sent)
        XCTAssertEqual(messages.first(where: { $0.clientMessageID == localEcho.clientMessageID })?.turnPayload?.textPrompt, "断线时不要卡在发送中")

        sockets[0].onSendAccepted?(try XCTUnwrap(localEcho.clientMessageID))
        try await Task.sleep(nanoseconds: 50_000_000)
        let afterStaleAccepted = conversationStore.messages(for: running.id)
        XCTAssertEqual(afterStaleAccepted.first(where: { $0.clientMessageID == localEcho.clientMessageID })?.sendStatus, .failed)
    }

    func testRunningSendFailureNoRolloutFoundMarksLocalEchoFailedAndRetainsRetryPayload() async throws {
        let project = makeProject(id: "proj_no_rollout_send")
        let running = makeSession(id: "sess_no_rollout_send", projectID: project.id, title: "No Rollout", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )
        let payload = CodexAppServerTurnPayload(input: [
            .text("继续这轮"),
            .image(url: "data:image/png;base64,AA==", detail: .high),
            .mention(name: "README", path: project.path)
        ])

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let sent = await store.sendTurn(payload)
        XCTAssertTrue(sent)
        let localEcho = try XCTUnwrap(conversationStore.messages(for: running.id).first { $0.role == .user })
        let clientMessageID = try XCTUnwrap(localEcho.clientMessageID)
        XCTAssertEqual(localEcho.sendStatus, .sending)

        sockets[0].onSendFailure?(clientMessageID, "app-server 错误 -32000：no rollout found")
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: running.id) { messages in
            messages.contains { $0.clientMessageID == clientMessageID && $0.sendStatus == .failed }
        }

        let failedMessage = try XCTUnwrap(conversationStore.messages(for: running.id).first { $0.clientMessageID == clientMessageID })
        XCTAssertEqual(failedMessage.turnPayload?.input, payload.input)
        XCTAssertEqual(failedMessage.turnPayload?.options.model, "gpt-5.5")
        XCTAssertTrue(payloadContainsInlineImage(failedMessage.turnPayload))
        XCTAssertTrue(payloadContainsMention(failedMessage.turnPayload, name: "README"))
        for _ in 0..<50 where store.errorMessage != "发送失败：app-server 错误 -32000：no rollout found" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.errorMessage, "发送失败：app-server 错误 -32000：no rollout found")
        XCTAssertNil(store.selectedForegroundActivity)
    }

    func testApprovalDecisionSendsThroughCurrentWebSocket() async throws {
        let project = makeProject(id: "proj_approval")
        let approval = ApprovalSummary(id: "approval-1", title: "运行 go test", kind: "command", count: 1)
        let waiting = AgentSession(
            id: "codex_thread_approval",
            projectID: project.id,
            project: project.id,
            dir: "/tmp/\(project.id)",
            title: "待审批",
            status: "waiting_for_approval",
            source: "codex",
            resumeID: "thread_approval",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            pendingApproval: approval
        )
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [waiting])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(waiting)
        await store.selectSession(waiting)
        XCTAssertEqual(sockets.count, 1)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        store.decideApproval(approval, accept: true)

        XCTAssertEqual(sockets[0].sentApprovals.count, 1)
        XCTAssertEqual(sockets[0].sentApprovals.first?.approvalID, "approval-1")
        XCTAssertEqual(sockets[0].sentApprovals.first?.decision, "accept")
        XCTAssertEqual(store.selectedSession?.status, "waiting_for_approval")
        XCTAssertEqual(store.selectedSession?.pendingApproval?.id, "approval-1")
        XCTAssertTrue(store.isApprovalDecisionPending(approval))

        sockets[0].onControlFailure?("interrupt failed")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(store.isApprovalDecisionPending(approval))

        sockets[0].onApprovalDecisionFailure?("approval-1", "write failed")
        for _ in 0..<80 where store.isApprovalDecisionPending(approval) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.isApprovalDecisionPending(approval))
        XCTAssertEqual(store.selectedSession?.pendingApproval?.id, "approval-1")

        store.decideApproval(approval, accept: true)
        XCTAssertTrue(store.isApprovalDecisionPending(approval))
        sockets[0].emitEvent(.approvalResolved(AgentEventMetadata(
            seq: nil,
            sessionID: waiting.id,
            turnID: nil,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: Date()
        )))
        for _ in 0..<80 where store.selectedSession?.pendingApproval != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.selectedSession?.status, "running")
        XCTAssertNil(store.selectedSession?.pendingApproval)
        XCTAssertFalse(store.isApprovalDecisionPending(approval))
    }

    func testApprovalRequestUpdatesSelectedSessionPendingApproval() async throws {
        let project = makeProject(id: "proj_approval_event")
        let running = makeSession(id: "sess_approval_event", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        let conversationStore = ConversationStore()
        let scheduler = FakeSessionReminderScheduler()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            sessionReminderScheduler: scheduler,
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        XCTAssertEqual(sockets.count, 1)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        sockets[0].emitEvent(.approvalRequest(
            AgentApprovalRequest(
                id: "cmd-approval",
                title: "运行 curl",
                body: "curl -I https://example.com",
                kind: "command",
                risk: "high"
            ),
            AgentEventMetadata(
                seq: 21,
                sessionID: running.id,
                turnID: "turn-approval",
                itemID: "cmd-approval",
                messageID: nil,
                clientMessageID: nil,
                revision: nil,
                createdAt: nil
            )
        ))
        for _ in 0..<80 where store.selectedSession?.pendingApproval?.id != "cmd-approval" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(store.selectedSession?.status, "waiting_for_approval")
        XCTAssertEqual(store.selectedSession?.pendingApproval?.title, "运行 curl")
        XCTAssertTrue(conversationStore.messages(for: running.id).contains { $0.kind == .approval })
        XCTAssertEqual(scheduler.runtimeNotifications, [
            SessionRuntimeNotification(
                id: "approval:\(running.id):cmd-approval",
                sessionID: running.id,
                title: "等待审批",
                body: "\(running.title)：运行 curl",
                kind: .approval
            )
        ])

        store.decideApproval(try XCTUnwrap(store.selectedSession?.pendingApproval), accept: true)

        XCTAssertEqual(sockets[0].sentApprovals.first?.approvalID, "cmd-approval")
        XCTAssertEqual(store.selectedSession?.pendingApproval?.id, "cmd-approval")
        XCTAssertEqual(store.selectedSession?.status, "waiting_for_approval")
        XCTAssertTrue(store.isApprovalDecisionPending(try XCTUnwrap(store.selectedSession?.pendingApproval)))
        XCTAssertTrue(conversationStore.messages(for: running.id).contains { message in
            message.kind == .approval && message.content.contains("等待审批：运行 curl")
        })
    }

    func testApprovalRequestSurvivesLateRunningStatusAndRefresh() async throws {
        let project = makeProject(id: "proj_approval_race")
        let running = makeSession(id: "sess_approval_race", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        sockets[0].emitEvent(.approvalRequest(
            AgentApprovalRequest(
                id: "cmd-race",
                title: "运行危险命令",
                body: "rm -rf build",
                kind: "command",
                risk: "high"
            ),
            AgentEventMetadata(
                seq: 41,
                sessionID: running.id,
                turnID: "turn-race",
                itemID: "cmd-race",
                messageID: nil,
                clientMessageID: nil,
                revision: nil,
                createdAt: nil
            )
        ))
        for _ in 0..<80 where store.selectedSession?.pendingApproval?.id != "cmd-race" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.selectedSession?.pendingApproval?.id, "cmd-race")

        sockets[0].emitEvent(.sessionStatus("running", AgentEventMetadata(
            seq: 42,
            sessionID: running.id,
            turnID: "turn-race",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.selectedSession?.pendingApproval?.id, "cmd-race")

        // 前台刷新或分页刷新拿到的普通 running 快照不能覆盖实时 approval_request。
        await store.refreshAll(autoAttach: false)
        XCTAssertEqual(store.selectedSession?.status, "waiting_for_approval")
        XCTAssertEqual(store.selectedSession?.pendingApproval?.id, "cmd-race")
    }

    func testRuntimeEventsScheduleCompletionAndFailureNotifications() async throws {
        let project = makeProject(id: "proj_runtime_notice")
        let running = makeSession(id: "sess_runtime_notice", projectID: project.id, title: "长任务", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        let conversationStore = ConversationStore()
        let scheduler = FakeSessionReminderScheduler()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            sessionReminderScheduler: scheduler,
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let completed = AgentEvent.turnCompleted(AgentEventMetadata(
            seq: 31,
            sessionID: running.id,
            turnID: "turn-done",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        ))
        sockets[0].emitEvent(completed)
        sockets[0].emitEvent(completed)
        for _ in 0..<80 where scheduler.runtimeNotifications.count < 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(scheduler.runtimeNotifications, [
            SessionRuntimeNotification(
                id: "completed:\(running.id):turn-done",
                sessionID: running.id,
                title: "会话已完成",
                body: running.title,
                kind: .completed
            )
        ])

        sockets[0].emitEvent(.sessionStatus("failed", AgentEventMetadata(
            seq: 32,
            sessionID: running.id,
            turnID: "turn-failed",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )))
        for _ in 0..<80 where scheduler.runtimeNotifications.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(scheduler.runtimeNotifications.last, SessionRuntimeNotification(
            id: "failed:\(running.id):turn-failed",
            sessionID: running.id,
            title: "会话失败",
            body: running.title,
            kind: .failed
        ))
    }

    func testEventReducerClearsPendingApprovalWhenServerRequestResolved() async throws {
        let reducer = EventReducer()
        let output = await reducer.reduce(
            .approvalResolved(AgentEventMetadata(
                seq: 31,
                sessionID: "sess_resolved",
                turnID: "turn_resolved",
                itemID: "99",
                messageID: nil,
                clientMessageID: nil,
                revision: nil,
                createdAt: nil
            )),
            fallbackSessionID: "fallback_session",
            outputIdleClearDelay: 0
        )

        XCTAssertEqual(output.pendingApprovalUpdates.count, 1)
        XCTAssertEqual(output.pendingApprovalUpdates.first?.0, "sess_resolved")
        XCTAssertNil(output.pendingApprovalUpdates.first?.1)
        XCTAssertEqual(output.statusUpdates.first?.0, "sess_resolved")
        XCTAssertEqual(output.statusUpdates.first?.1, "running")
        XCTAssertEqual(output.pendingApprovalTaskClears, ["sess_resolved"])
        XCTAssertEqual(output.messageMutations.count, 1)
        if case .resolveLatestPendingApproval(let sessionID) = output.messageMutations[0] {
            XCTAssertEqual(sessionID, "sess_resolved")
        } else {
            XCTFail("Expected resolveLatestPendingApproval mutation")
        }
    }

    func testEventReducerDoesNotClearPendingApprovalForActiveStatusRefresh() async throws {
        let reducer = EventReducer()
        let running = await reducer.reduce(
            .sessionStatus("running", AgentEventMetadata(
                seq: 33,
                sessionID: "sess_active",
                turnID: "turn_active",
                itemID: nil,
                messageID: nil,
                clientMessageID: nil,
                revision: nil,
                createdAt: nil
            )),
            fallbackSessionID: "fallback_session",
            outputIdleClearDelay: 0
        )

        XCTAssertEqual(running.statusUpdates.first?.0, "sess_active")
        XCTAssertEqual(running.statusUpdates.first?.1, "running")
        XCTAssertTrue(running.pendingApprovalUpdates.isEmpty)

        let failed = await reducer.reduce(
            .sessionStatus("failed", AgentEventMetadata(
                seq: 34,
                sessionID: "sess_active",
                turnID: "turn_active",
                itemID: nil,
                messageID: nil,
                clientMessageID: nil,
                revision: nil,
                createdAt: nil
            )),
            fallbackSessionID: "fallback_session",
            outputIdleClearDelay: 0
        )

        XCTAssertEqual(failed.pendingApprovalUpdates.count, 1)
        XCTAssertEqual(failed.pendingApprovalUpdates.first?.0, "sess_active")
        XCTAssertNil(failed.pendingApprovalUpdates.first?.1)
    }

    func testConversationStoreResolvesRemotePendingApprovalAndDeduplicatesReplay() {
        let store = ConversationStore()
        let sessionID = "sess_remote_approval"
        let waitingText = "等待审批：运行 curl，风险：high"

        store.appendSystem(waitingText, sessionID: sessionID, kind: .approval)
        store.appendSystem(waitingText, sessionID: sessionID, kind: .approval)

        XCTAssertEqual(store.messages(for: sessionID).filter { $0.kind == .approval }.count, 1)

        store.resolveLatestPendingApproval(sessionID: sessionID)

        XCTAssertEqual(store.messages(for: sessionID).filter { $0.kind == .approval }.count, 1)
        XCTAssertEqual(store.messages(for: sessionID).last?.content, "审批已解决：运行 curl")
    }

    func testSessionStoreReplaysDirectAppServerEventStreamFixture() async throws {
        let sessionID = "thr_fixture_stream"
        let project = AgentProject(id: "proj_fixture_stream", name: "Fixture Stream", path: "/tmp/fixture-stream")
        let running = makeSession(id: sessionID, projectID: project.id, title: "Fixture 直连", status: "running", source: "codex", resumeID: sessionID)
        let appStore = AppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            historyPages: [sessionID: HistoryMessagesPage(messages: [])]
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        XCTAssertEqual(sockets.count, 1)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let events = try loadDirectAppServerEventStreamFixture(named: "direct_app_server_approval_stream.jsonl")
        let approvalIndex = try XCTUnwrap(events.firstIndex {
            if case .approvalRequest = $0 {
                return true
            }
            return false
        })

        for event in events[..<approvalIndex] {
            sockets[0].emitEvent(event)
        }
        let completedMessages = try await waitForConversationMessages(in: conversationStore, sessionID: sessionID) { messages in
            messages.contains { $0.role == .assistant && $0.content == "第一段：真实 app-server 事件流。" && $0.sendStatus == .confirmed }
        }

        XCTAssertEqual(completedMessages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(completedMessages.first?.stableID, "appserver:turn_fixture_stream:assistant_fixture")
        XCTAssertEqual(completedMessages.first?.turnID, "turn_fixture_stream")
        XCTAssertEqual(completedMessages.first?.itemID, "assistant_fixture")
        XCTAssertEqual(conversationStore.lastSeenSeq(for: sessionID), 5)
        XCTAssertEqual(store.selectedSession?.status, "running")
        XCTAssertNil(store.selectedSession?.pendingApproval)
        XCTAssertNil(store.selectedForegroundActivity)

        sockets[0].emitEvent(events[approvalIndex])
        for _ in 0..<80 where store.selectedSession?.pendingApproval?.id != "cmd_fixture_approval" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let pendingApproval = try XCTUnwrap(store.selectedSession?.pendingApproval)
        XCTAssertEqual(store.selectedSession?.status, "waiting_for_approval")
        XCTAssertEqual(pendingApproval.title, "Agent 请求执行命令：go test ./ios/MimiRemote")
        XCTAssertTrue(conversationStore.messages(for: sessionID).contains { $0.kind == .approval && $0.content.contains("等待审批") })

        store.decideApproval(pendingApproval, accept: true)

        XCTAssertEqual(sockets[0].sentApprovals.first?.approvalID, "cmd_fixture_approval")
        XCTAssertEqual(sockets[0].sentApprovals.first?.decision, "accept")
        XCTAssertEqual(store.selectedSession?.pendingApproval?.id, "cmd_fixture_approval")

        for event in events.dropFirst(approvalIndex + 1) {
            sockets[0].emitEvent(event)
        }
        for _ in 0..<80 where conversationStore.lastSeenSeq(for: sessionID) != 7 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(conversationStore.lastSeenSeq(for: sessionID), 7)
        XCTAssertNil(store.selectedSession?.pendingApproval)
        XCTAssertNil(store.selectedForegroundActivity)
    }

    func testApprovalDecisionKeepsConversationRecordPendingUntilResolved() async throws {
        let project = makeProject(id: "proj_decline")
        let approval = ApprovalSummary(id: "approval-decline", title: "运行危险命令", kind: "command", count: 1)
        let waiting = AgentSession(
            id: "codex_thread_decline",
            projectID: project.id,
            project: project.id,
            dir: "/tmp/\(project.id)",
            title: "待审批",
            status: "waiting_for_approval",
            source: "codex",
            resumeID: "thread_decline",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            pendingApproval: approval
        )
        let appStore = AppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        conversationStore.appendSystem("等待审批：运行危险命令，风险：high", sessionID: waiting.id, kind: .approval)
        let client = MockSessionStoreClient(projects: [project], sessions: [waiting])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(waiting)
        await store.selectSession(waiting)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        store.decideApproval(approval, accept: false)

        XCTAssertEqual(sockets[0].sentApprovals.first?.decision, "decline")
        XCTAssertTrue(store.isApprovalDecisionPending(approval))
        XCTAssertEqual(store.selectedSession?.pendingApproval?.id, approval.id)
        XCTAssertEqual(conversationStore.messages(for: waiting.id).filter { $0.kind == .approval }.last?.content, "等待审批：运行危险命令，风险：high")
    }

    func testRuntimeSummaryEventsKeepStructuredTimelineKinds() {
        let store = ConversationStore()
        let sessionID = "sess_runtime_summary"

        store.appendSystem("文件变更：README.md modified", sessionID: sessionID, kind: .fileChangeSummary)
        store.appendSystem("等待审批：运行 go test", sessionID: sessionID, kind: .approval)
        store.appendSystem("运行错误：timeout", sessionID: sessionID, kind: .error)

        XCTAssertEqual(store.messages(for: sessionID).map(\.kind), [.fileChangeSummary, .approval, .error])
    }

    func testToolMessageCompletedFallsBackToCommandSummaryKind() throws {
        let store = ConversationStore()
        let sessionID = "sess_tool_summary"
        let message = try AgentAPIClient.decoder.decode(
            AgentMessage.self,
            from: Data("""
            {
              "id": "tool:1",
              "session_id": "\(sessionID)",
              "role": "tool",
              "content": "go test ./... 通过",
              "created_at": "2026-06-03T10:00:00Z",
              "revision": 1,
              "send_status": "confirmed"
            }
            """.utf8)
        )

        store.completeMessage(message, metadata: .empty, fallbackSessionID: sessionID)

        let rendered = try XCTUnwrap(store.messages(for: sessionID).first)
        XCTAssertEqual(rendered.role, .system)
        XCTAssertEqual(rendered.kind, .commandSummary)
        XCTAssertEqual(rendered.content, "go test ./... 通过")
    }

    func testStructuredAssistantDeltaCreatesStableBubble() {
        let store = ConversationStore()
        let sessionID = "sess_structured_delta"

        store.applyAssistantDelta(
            AgentDelta(text: "结构化回复", role: .assistant, kind: .message),
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
        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "结构化回复")
        XCTAssertEqual(messages.first?.stableID, "item_1")
    }

    func testBootstrapRetriesUntilProjectsLoadAfterTransientFailures() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_1", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = FlakyBootstrapClient(failuresBeforeSuccess: 2, projects: [project], sessions: [session])
        let appStore = AppStore()
        appStore.token = "test-token" // 让 isConfigured 为真，否则 bootstrap 直接返回。
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.bootstrap()

        XCTAssertEqual(client.projectsCallCount, 3) // 失败 2 次 + 成功 1 次
        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertNil(store.errorMessage)
    }

    func testBootstrapRetriesUntilSessionsLoadWhenGatewayStartsLate() async {
        let project = makeProject(id: "proj_late_gateway")
        let session = makeSession(id: "codex_late", projectID: project.id, title: "首启恢复", status: "history", source: "codex", resumeID: "history")
        // projects 立刻可用（agentd HTTP 已就绪），但 app-server gateway 上游晚 2 次才接受连接，
        // sessions 前两次抛错。冷启动 bootstrap 必须继续重试，而不能一拿到 projects 就收手。
        let client = FlakyBootstrapClient(
            failuresBeforeSuccess: 0,
            sessionFailuresBeforeSuccess: 2,
            projects: [project],
            sessions: [session]
        )
        let appStore = AppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project, lastOpenedAt: Date(timeIntervalSince1970: 10))],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client }
        )

        await store.bootstrap()

        XCTAssertEqual(client.sessionsCallCount, 3) // 会话失败 2 次 + 成功 1 次
        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertEqual(store.filteredSessions.map(\.id), [session.id])
        XCTAssertNil(store.errorMessage)
    }

    func testBootstrapDoesNotRetryWhenBackendHasNoProjects() async {
        let client = FlakyBootstrapClient(failuresBeforeSuccess: 0, projects: [], sessions: [])
        let appStore = AppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.bootstrap()

        // 成功但后端确实没有项目时不应空转重试。
        XCTAssertEqual(client.projectsCallCount, 1)
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    func testConcurrentSelectedProjectRefreshesShareOneListRequest() async throws {
        let project = makeProject(id: "proj_coalesced_list")
        let session = makeSession(id: "thread_coalesced_list", projectID: project.id, title: "合并列表", status: "history", source: "codex")
        let client = BlockingSessionListRefreshClient(projects: [project], page: SessionsPage(sessions: [session]))
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        let first = Task { await store.refreshSelectedProjectSessions(showLoading: true) }
        let second = Task { await store.refreshSelectedProjectSessions(showLoading: true) }
        await client.waitForBlockedSessionListRefresh()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(client.sessionsPageCallCount, 2, "bootstrap 后的两个并发刷新必须共享一个上游 thread/list")
        client.releaseBlockedSessionListRefresh()
        await first.value
        await second.value
    }

    func testMultiRuntimeHistoryPreservesEconomyAndFullLoadModes() async throws {
        let project = AgentProject(id: "proj_multi_history_mode", name: "History Mode", path: "/tmp/multi-history-mode")
        let config = makeDirectAppServerConfig(
            project: project,
            allowedMethods: [
                "initialize", "initialized", "thread/list", "thread/start", "thread/read",
                "thread/turns/list", "turn/start", "turn/interrupt"
            ]
        )
        let codexTransport = FakeCodexAppServerTransport()
        let claudeTransport = FakeCodexAppServerTransport()
        let client = MultiRuntimeSessionAPIClient(
            codexRuntime: CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787",
                token: "outer-token",
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

        let listTask = Task { try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 20) }
        let initialize = try await waitForFakeAppServerRequest(codexTransport, method: "initialize")
        transportResponse(codexTransport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let list = try await waitForFakeAppServerRequest(codexTransport, method: "thread/list", after: 1)
        transportResponse(codexTransport, id: list.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "thread_history_mode", cwd: project.path, source: "appServer", updatedAt: 1780493000)
        ], nextCursor: nil))
        _ = try await listTask.value

        let economyTask = Task {
            try await client.messagesPage(sessionID: "thread_history_mode", before: nil, limit: 20, loadMode: .economy)
        }
        let economyRequest = try await waitForFakeAppServerRequest(codexTransport, method: "thread/turns/list", after: 2)
        XCTAssertEqual(economyRequest.params?.objectValue?["itemsView"]?.stringValue, "summary")
        transportResponse(codexTransport, id: economyRequest.id, result: #"{"data":[],"nextCursor":null}"#)
        let economyPage = try await economyTask.value
        XCTAssertEqual(economyPage.loadMode, .economy)

        let fullTask = Task {
            try await client.messagesPage(sessionID: "thread_history_mode", before: nil, limit: 20, loadMode: .full)
        }
        let fullRequest = try await waitForFakeAppServerRequest(codexTransport, method: "thread/turns/list", after: 3)
        XCTAssertEqual(fullRequest.params?.objectValue?["itemsView"]?.stringValue, "full")
        transportResponse(codexTransport, id: fullRequest.id, result: #"{"data":[],"nextCursor":null}"#)
        let fullPage = try await fullTask.value
        XCTAssertEqual(fullPage.loadMode, .full)
    }
}

private final class MockWebSocketClient: SessionWebSocketClient {
    var onEvent: ((AgentEvent) -> Void)?
    var onStatus: ((WebSocketStatus) -> Void)?
    var onSendAccepted: ((ClientMessageID?) -> Void)?
    var onSendFailure: ((ClientMessageID?, String) -> Void)?
    var onApprovalDecisionFailure: ((String, String) -> Void)?
    var onUserInputResponseFailure: ((String, String) -> Void)?
    var onControlFailure: ((String) -> Void)?

    private(set) var connectedSessionIDs: [SessionID] = []
    private(set) var replayBufferedEventsByConnect: [Bool] = []
    private(set) var sentInputs: [(text: String, clientMessageID: ClientMessageID?)] = []
    private(set) var sentTurns: [(payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?)] = []
    private(set) var sentGuidance: [(payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?, expectedTurnID: TurnID)] = []
    private(set) var sentCtrlCCount = 0
    private(set) var sentApprovals: [(approvalID: String, decision: String, message: String?)] = []
    private(set) var sentUserInputResponses: [(requestID: String, answers: [String: [String]])] = []
    private(set) var disconnectCallCount = 0
    var sendTurnResult = true
    var sendGuidanceResult = true
    var sendCtrlCResult = true

    func connect(sessionID: SessionID) {
        connectedSessionIDs.append(sessionID)
        replayBufferedEventsByConnect.append(true)
        onStatus?(.connecting)
    }

    func connect(sessionID: SessionID, replayBufferedEvents: Bool) {
        connectedSessionIDs.append(sessionID)
        replayBufferedEventsByConnect.append(replayBufferedEvents)
        onStatus?(.connecting)
    }

    func disconnect() {
        disconnectCallCount += 1
        onStatus?(.disconnected)
    }

    func sendInput(_ text: String, clientMessageID: ClientMessageID?) -> Bool {
        sentInputs.append((text, clientMessageID))
        return true
    }

    func sendTurn(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?) -> Bool {
        sentTurns.append((payload, clientMessageID))
        return sendTurnResult
    }

    func sendGuidance(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?, expectedTurnID: TurnID) -> Bool {
        sentGuidance.append((payload, clientMessageID, expectedTurnID))
        return sendGuidanceResult
    }

    func sendCtrlC() -> Bool {
        sentCtrlCCount += 1
        return sendCtrlCResult
    }

    func sendApprovalDecision(approvalID: String, decision: String, message: String?) -> Bool {
        sentApprovals.append((approvalID, decision, message))
        return true
    }

    func sendUserInputResponse(requestID: String, answers: [String: [String]]) -> Bool {
        sentUserInputResponses.append((requestID, answers))
        return true
    }

    func emitStatus(_ status: WebSocketStatus) {
        onStatus?(status)
    }

    func emitEvent(_ event: AgentEvent) {
        onEvent?(event)
    }
}

private final class DelayedCreateSessionClient: SessionStoreAPIClient {
    let projectsResult: [AgentProject]
    let sessionsResult: [AgentSession]
    private var createContinuations: [CheckedContinuation<CreateSessionResponse, Error>] = []
    private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var createPayloads: [CreateSessionRequest] = []

    init(projects: [AgentProject], sessions: [AgentSession]) {
        self.projectsResult = projects
        self.sessionsResult = sessions
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        sessionsResult
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        createPayloads.append(payload)
        return try await withCheckedThrowingContinuation { continuation in
            createContinuations.append(continuation)
            notifyRequestCountWaiters()
        }
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        []
    }

    func waitForCreateRequestCount(_ count: Int) async {
        guard createReadyCount < count else {
            return
        }
        await withCheckedContinuation { continuation in
            guard createReadyCount < count else {
                continuation.resume()
                return
            }
            requestCountWaiters.append((count, continuation))
        }
    }

    func resolveCreate(with result: Result<CreateSessionResponse, Error>, at index: Int = 0) {
        switch result {
        case .success(let response):
            createContinuations[index].resume(returning: response)
        case .failure(let error):
            createContinuations[index].resume(throwing: error)
        }
    }

    private func notifyRequestCountWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in requestCountWaiters {
            if createReadyCount >= waiter.0 {
                waiter.1.resume()
            } else {
                pending.append(waiter)
            }
        }
        requestCountWaiters = pending
    }

    private var createReadyCount: Int {
        min(createPayloads.count, createContinuations.count)
    }
}

private struct RequestedGitAction: Equatable {
    let path: String
    let action: GitActionKind
    let files: [String]
}

private struct RequestedGitPatchAction: Equatable {
    let path: String
    let action: GitActionKind
    let patch: String
}

private struct RequestedGitCommit: Equatable {
    let path: String
    let message: String
}

private struct RequestedGitPush: Equatable {
    let path: String
    let remote: String?
}

private struct RequestedGitPullRequest: Equatable {
    let path: String
    let title: String
    let body: String
    let draft: Bool
}

private struct RequestedCommandActionRun: Equatable {
    let path: String
    let id: String
    let confirmed: Bool
}

private struct RequestedWorktreeCreate: Equatable {
    let path: String
    let name: String?
    let base: String?
    let branch: String?
}

private struct RequestedWorktreeDelete: Equatable {
    let path: String
    let force: Bool
}

private struct RequestedSessionArchive: Equatable {
    let id: String
    let archived: Bool
}

private struct RequestedSessionFork: Equatable {
    let threadID: String
    let workspaceID: String
}

private struct RequestedThreadGoalSet: Equatable {
    let threadID: String
    let objective: String?
    let status: ThreadGoalStatus?
    let tokenBudget: Int64?
}

private final class FakeSessionReminderScheduler: SessionReminderScheduling {
    private(set) var scheduled: [SessionReminder] = []
    private(set) var runtimeNotifications: [SessionRuntimeNotification] = []
    private(set) var canceledSessionIDs: [SessionID] = []

    func schedule(_ reminder: SessionReminder) async throws {
        scheduled.append(reminder)
    }

    func notify(_ notification: SessionRuntimeNotification) async throws {
        runtimeNotifications.append(notification)
    }

    func cancel(sessionID: SessionID) {
        canceledSessionIDs.append(sessionID)
    }
}

private final class MockSessionStoreClient: SessionStoreAPIClient {
    let projectsResult: [AgentProject]
    let sessionsResult: [AgentSession]
    let projectSessions: [String: [AgentSession]]
    let workspaceSessions: [String: [AgentSession]]
    let projectPages: [String: SessionsPage]
    let workspacePages: [String: SessionsPage]
    let cursorPages: [String: SessionsPage]
    let createSessionResponse: CreateSessionResponse?
    let sessionArchiveResults: [String: Result<Void, Error>]
    let sessionForkResults: [String: Result<AgentSession, Error>]
    let threadGoalSetResults: [String: Result<ThreadGoal, Error>]
    let sessionResponses: [String: SessionResponse]
    let messagesResult: [CodexHistoryMessage]
    let historyPages: [String: HistoryMessagesPage]
    let historyCursorPages: [String: HistoryMessagesPage]
    let workspaceSessionsError: [String: Error]
    let capabilityResults: [String: Result<CapabilityListResponse, Error>]
    let resolveResults: [String: Result<AgentWorkspace, Error>]
    let worktreeCreateResults: [String: Result<WorktreeCreateResponse, Error>]
    let worktreeBranchResults: [String: Result<WorktreeBranchListResponse, Error>]
    let worktreeListResult: Result<[WorktreeListItem], Error>?
    let worktreeDeleteResults: [String: Result<WorktreeDeleteResponse, Error>]
    let worktreePruneResult: Result<WorktreePruneResponse, Error>?
    let directoryListResults: [String: Result<DirectoryListResponse, Error>]
    let fileReadResults: [String: Result<FileReadResponse, Error>]
    let historyMediaResults: [String: Result<FileReadResponse, Error>]
    let commandActionResults: [String: Result<[AgentCommandAction], Error>]
    let commandActionRunResults: [String: Result<CommandActionRunResponse, Error>]
    let gitStatusResults: [String: Result<GitStatusResponse, Error>]
    let gitActionResults: [String: Result<GitStatusResponse, Error>]
    let gitPatchActionResults: [String: Result<GitStatusResponse, Error>]
    let gitCommitResults: [String: Result<GitStatusResponse, Error>]
    let gitPushResults: [String: Result<GitPushResponse, Error>]
    let gitPullRequestResults: [String: Result<GitPullRequestResponse, Error>]
    let gitPullRequestStatusResults: [String: Result<GitPullRequestStatusResponse, Error>]
    let messagesError: Error?
    let modelOptionsResult: [CodexAppServerModelOption]
    let modelOptionsError: Error?
    var requestedProjectIDs: [String?] = []
    var requestedWorkspaceIDs: [String] = []
    var requestedCapabilityPaths: [String?] = []
    var requestedResolvePaths: [String] = []
    var requestedWorktreeCreates: [RequestedWorktreeCreate] = []
    var requestedWorktreeBranchPaths: [String] = []
    var requestedWorktreeDeletes: [RequestedWorktreeDelete] = []
    private(set) var worktreePruneCallCount = 0
    var requestedDirectoryPaths: [String] = []
    var requestedFileReadPaths: [String] = []
    var requestedHistoryMediaIDs: [String] = []
    var requestedCommandActionPaths: [String] = []
    var requestedCommandActionRuns: [RequestedCommandActionRun] = []
    var requestedGitStatusPaths: [String] = []
    var requestedGitActions: [RequestedGitAction] = []
    var requestedGitPatchActions: [RequestedGitPatchAction] = []
    var requestedGitCommits: [RequestedGitCommit] = []
    var requestedGitPushes: [RequestedGitPush] = []
    var requestedGitPullRequests: [RequestedGitPullRequest] = []
    var requestedGitPullRequestStatusPaths: [String] = []
    var requestedSessionIDs: [String] = []
    var requestedSessionAfterSeqs: [EventSequence?] = []
    var requestedSessionArchives: [RequestedSessionArchive] = []
    var requestedSessionForks: [RequestedSessionFork] = []
    var requestedThreadGoalSets: [RequestedThreadGoalSet] = []
    var requestedMessageSessionIDs: [String] = []
    var requestedMessageCursors: [String?] = []
    var createPayloads: [CreateSessionRequest] = []
    private(set) var worktreeListCallCount = 0
    private(set) var modelOptionsCallCount = 0

    init(
        projects: [AgentProject],
        sessions: [AgentSession],
        projectSessions: [String: [AgentSession]] = [:],
        workspaceSessions: [String: [AgentSession]] = [:],
        projectPages: [String: SessionsPage] = [:],
        workspacePages: [String: SessionsPage] = [:],
        cursorPages: [String: SessionsPage] = [:],
        createSessionResponse: CreateSessionResponse? = nil,
        sessionArchiveResults: [String: Result<Void, Error>] = [:],
        sessionForkResults: [String: Result<AgentSession, Error>] = [:],
        threadGoalSetResults: [String: Result<ThreadGoal, Error>] = [:],
        sessionResponses: [String: SessionResponse] = [:],
        messagesResult: [CodexHistoryMessage]? = nil,
        historyPages: [String: HistoryMessagesPage] = [:],
        historyCursorPages: [String: HistoryMessagesPage] = [:],
        workspaceSessionsError: [String: Error] = [:],
        capabilityResults: [String: Result<CapabilityListResponse, Error>] = [:],
        resolveResults: [String: Result<AgentWorkspace, Error>] = [:],
        worktreeCreateResults: [String: Result<WorktreeCreateResponse, Error>] = [:],
        worktreeBranchResults: [String: Result<WorktreeBranchListResponse, Error>] = [:],
        worktreeListResult: Result<[WorktreeListItem], Error>? = nil,
        worktreeDeleteResults: [String: Result<WorktreeDeleteResponse, Error>] = [:],
        worktreePruneResult: Result<WorktreePruneResponse, Error>? = nil,
        directoryListResults: [String: Result<DirectoryListResponse, Error>] = [:],
        fileReadResults: [String: Result<FileReadResponse, Error>] = [:],
        historyMediaResults: [String: Result<FileReadResponse, Error>] = [:],
        commandActionResults: [String: Result<[AgentCommandAction], Error>] = [:],
        commandActionRunResults: [String: Result<CommandActionRunResponse, Error>] = [:],
        gitStatusResults: [String: Result<GitStatusResponse, Error>] = [:],
        gitActionResults: [String: Result<GitStatusResponse, Error>] = [:],
        gitPatchActionResults: [String: Result<GitStatusResponse, Error>] = [:],
        gitCommitResults: [String: Result<GitStatusResponse, Error>] = [:],
        gitPushResults: [String: Result<GitPushResponse, Error>] = [:],
        gitPullRequestResults: [String: Result<GitPullRequestResponse, Error>] = [:],
        gitPullRequestStatusResults: [String: Result<GitPullRequestStatusResponse, Error>] = [:],
        messagesError: Error? = nil,
        modelOptions: [CodexAppServerModelOption] = [],
        modelOptionsError: Error? = nil
    ) {
        self.projectsResult = projects
        self.sessionsResult = sessions
        self.projectSessions = projectSessions
        self.workspaceSessions = workspaceSessions
        self.projectPages = projectPages
        self.workspacePages = workspacePages
        self.cursorPages = cursorPages
        self.createSessionResponse = createSessionResponse
        self.sessionArchiveResults = sessionArchiveResults
        self.sessionForkResults = sessionForkResults
        self.threadGoalSetResults = threadGoalSetResults
        self.sessionResponses = sessionResponses
        self.messagesResult = messagesResult ?? [
            CodexHistoryMessage(role: "user", content: "历史问题", createdAt: Date(timeIntervalSince1970: 1)),
            CodexHistoryMessage(role: "assistant", content: "历史回答", createdAt: Date(timeIntervalSince1970: 2))
        ]
        self.historyPages = historyPages
        self.historyCursorPages = historyCursorPages
        self.workspaceSessionsError = workspaceSessionsError
        self.capabilityResults = capabilityResults
        self.resolveResults = resolveResults
        self.worktreeCreateResults = worktreeCreateResults
        self.worktreeBranchResults = worktreeBranchResults
        self.worktreeListResult = worktreeListResult
        self.worktreeDeleteResults = worktreeDeleteResults
        self.worktreePruneResult = worktreePruneResult
        self.directoryListResults = directoryListResults
        self.fileReadResults = fileReadResults
        self.historyMediaResults = historyMediaResults
        self.commandActionResults = commandActionResults
        self.commandActionRunResults = commandActionRunResults
        self.gitStatusResults = gitStatusResults
        self.gitActionResults = gitActionResults
        self.gitPatchActionResults = gitPatchActionResults
        self.gitCommitResults = gitCommitResults
        self.gitPushResults = gitPushResults
        self.gitPullRequestResults = gitPullRequestResults
        self.gitPullRequestStatusResults = gitPullRequestStatusResults
        self.messagesError = messagesError
        self.modelOptionsResult = modelOptions
        self.modelOptionsError = modelOptionsError
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
    }

    func modelOptions() async throws -> [CodexAppServerModelOption] {
        modelOptionsCallCount += 1
        if let modelOptionsError {
            throw modelOptionsError
        }
        return modelOptionsResult
    }

    func capabilities(path: String?) async throws -> CapabilityListResponse {
        requestedCapabilityPaths.append(path)
        let key = path ?? ""
        switch capabilityResults[key] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func resolveWorkspace(path: String) async throws -> AgentWorkspace {
        requestedResolvePaths.append(path)
        switch resolveResults[path] {
        case .success(let workspace):
            return workspace
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse {
        requestedWorktreeCreates.append(RequestedWorktreeCreate(path: path, name: name, base: base, branch: branch))
        switch worktreeCreateResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse {
        requestedWorktreeBranchPaths.append(path)
        switch worktreeBranchResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func listWorktrees() async throws -> [WorktreeListItem] {
        worktreeListCallCount += 1
        switch worktreeListResult {
        case .success(let items):
            return items
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func deleteWorktree(path: String, force: Bool) async throws -> WorktreeDeleteResponse {
        requestedWorktreeDeletes.append(RequestedWorktreeDelete(path: path, force: force))
        switch worktreeDeleteResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func pruneMissingWorktrees() async throws -> WorktreePruneResponse {
        worktreePruneCallCount += 1
        switch worktreePruneResult {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func listDirectories(path: String) async throws -> DirectoryListResponse {
        requestedDirectoryPaths.append(path)
        switch directoryListResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func readFile(path: String) async throws -> FileReadResponse {
        requestedFileReadPaths.append(path)
        switch fileReadResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func readHistoryMedia(id: String) async throws -> FileReadResponse {
        requestedHistoryMediaIDs.append(id)
        switch historyMediaResults[id] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func commandActions(path: String) async throws -> [AgentCommandAction] {
        requestedCommandActionPaths.append(path)
        switch commandActionResults[path] {
        case .success(let actions):
            return actions
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse {
        requestedCommandActionRuns.append(RequestedCommandActionRun(path: path, id: id, confirmed: confirmed))
        let key = "\(path)#\(id)"
        switch commandActionRunResults[key] ?? commandActionRunResults[id] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func gitStatus(path: String) async throws -> GitStatusResponse {
        requestedGitStatusPaths.append(path)
        switch gitStatusResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func gitAction(path: String, action: GitActionKind, files: [String]) async throws -> GitStatusResponse {
        requestedGitActions.append(RequestedGitAction(path: path, action: action, files: files))
        switch gitActionResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func gitPatchAction(path: String, action: GitActionKind, patch: String) async throws -> GitStatusResponse {
        requestedGitPatchActions.append(RequestedGitPatchAction(path: path, action: action, patch: patch))
        switch gitPatchActionResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func gitCommit(path: String, message: String) async throws -> GitStatusResponse {
        requestedGitCommits.append(RequestedGitCommit(path: path, message: message))
        switch gitCommitResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func gitPush(path: String, remote: String?) async throws -> GitPushResponse {
        requestedGitPushes.append(RequestedGitPush(path: path, remote: remote))
        switch gitPushResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func gitCreatePullRequest(path: String, title: String, body: String, draft: Bool) async throws -> GitPullRequestResponse {
        requestedGitPullRequests.append(RequestedGitPullRequest(path: path, title: title, body: body, draft: draft))
        switch gitPullRequestResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse {
        requestedGitPullRequestStatusPaths.append(path)
        switch gitPullRequestStatusResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?) async throws -> SessionsPage {
        requestedWorkspaceIDs.append(workspace.id)
        if let error = workspaceSessionsError[workspace.id] {
            throw error
        }
        if let page = workspacePages[workspace.id] {
            return page
        }
        if let sessions = workspaceSessions[workspace.id] {
            return SessionsPage(sessions: sessions)
        }
        // 没有注入错误时沿用 projectID 路径，保持既有 workspace→rootProjectID 映射测试不变。
        return try await sessionsPage(projectID: workspace.rootProjectID ?? workspace.id, cursor: cursor, limit: limit)
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        requestedProjectIDs.append(projectID)
        if let projectID, let sessions = projectSessions[projectID] {
            return sessions
        }
        return sessionsResult
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        requestedProjectIDs.append(projectID)
        if let cursor, let page = cursorPages[cursor] {
            return page
        }
        if let projectID, let page = projectPages[projectID] {
            return page
        }
        if let projectID, let sessions = projectSessions[projectID] {
            return SessionsPage(sessions: sessions)
        }
        return SessionsPage(sessions: sessionsResult)
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        requestedSessionIDs.append(id)
        requestedSessionAfterSeqs.append(afterSeq)
        guard let response = sessionResponses[id] else {
            throw MockError.unimplemented
        }
        return response
    }

    func setThreadGoal(
        threadID: String,
        objective: String?,
        status: ThreadGoalStatus?,
        tokenBudget: Int64?
    ) async throws -> ThreadGoal {
        requestedThreadGoalSets.append(RequestedThreadGoalSet(
            threadID: threadID,
            objective: objective,
            status: status,
            tokenBudget: tokenBudget
        ))
        switch threadGoalSetResults[threadID] {
        case .success(let goal):
            return goal
        case .failure(let error):
            throw error
        case .none:
            return ThreadGoal(
                threadID: threadID,
                objective: objective ?? "测试目标",
                status: status ?? .active,
                tokenBudget: tokenBudget
            )
        }
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

    func setSessionArchived(id: String, archived: Bool) async throws {
        requestedSessionArchives.append(RequestedSessionArchive(id: id, archived: archived))
        switch sessionArchiveResults[id] {
        case .success:
            return
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func forkSession(threadID: String, workspace: AgentWorkspace) async throws -> AgentSession {
        requestedSessionForks.append(RequestedSessionFork(threadID: threadID, workspaceID: workspace.id))
        switch sessionForkResults[threadID] {
        case .success(let session):
            return session
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        requestedMessageSessionIDs.append(sessionID)
        requestedMessageCursors.append(before)
        if let before, let page = historyCursorPages[before] {
            return page.messages
        }
        if let page = historyPages[sessionID] {
            return page.messages
        }
        if let messagesError {
            throw messagesError
        }
        return messagesResult
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        requestedMessageSessionIDs.append(sessionID)
        requestedMessageCursors.append(before)
        if let before, let page = historyCursorPages[before] {
            return page
        }
        if let page = historyPages[sessionID] {
            return page
        }
        if let messagesError {
            throw messagesError
        }
        return HistoryMessagesPage(messages: messagesResult)
    }
}

private final class MutableSessionPageClient: SessionStoreAPIClient {
    let projectsResult: [AgentProject]
    var page: SessionsPage
    var cursorPages: [String: SessionsPage]
    var historyPages: [SessionID: HistoryMessagesPage]
    var historyCursorPages: [String: HistoryMessagesPage]
    var requestedMessageCursors: [String?] = []

    init(
        projects: [AgentProject],
        page: SessionsPage,
        cursorPages: [String: SessionsPage] = [:],
        historyPages: [SessionID: HistoryMessagesPage] = [:],
        historyCursorPages: [String: HistoryMessagesPage] = [:]
    ) {
        self.projectsResult = projects
        self.page = page
        self.cursorPages = cursorPages
        self.historyPages = historyPages
        self.historyCursorPages = historyCursorPages
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        page.sessions
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        if let cursor, let page = cursorPages[cursor] {
            return page
        }
        return page
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        let page = try await messagesPage(sessionID: sessionID, before: before, limit: limit)
        return page.messages
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        requestedMessageCursors.append(before)
        if let before, let page = historyCursorPages[before] {
            return page
        }
        if let page = historyPages[sessionID] {
            return page
        }
        return HistoryMessagesPage(messages: [])
    }
}

private final class BlockingSessionListRefreshClient: SessionStoreAPIClient {
    let projectsResult: [AgentProject]
    let page: SessionsPage
    private(set) var requestedMessageCursors: [String?] = []
    private(set) var sessionsPageCallCount = 0
    private var blockedListRefreshCount = 0
    private var blockedListContinuations: [CheckedContinuation<SessionsPage, Never>] = []
    private var blockedListWaiters: [CheckedContinuation<Void, Never>] = []

    init(projects: [AgentProject], page: SessionsPage) {
        self.projectsResult = projects
        self.page = page
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        page.sessions
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        sessionsPageCallCount += 1
        guard sessionsPageCallCount > 1 else {
            return page
        }
        // 第二次列表请求模拟慢 thread/list：当前会话刷新不应该等它结束。
        return await withCheckedContinuation { continuation in
            blockedListContinuations.append(continuation)
            blockedListRefreshCount += 1
            notifyBlockedListWaiters()
        }
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        let page = try await messagesPage(sessionID: sessionID, before: before, limit: limit)
        return page.messages
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        requestedMessageCursors.append(before)
        return HistoryMessagesPage(
            messages: [
                CodexHistoryMessage(id: "rollout:100", role: "assistant", content: "历史回答", createdAt: Date(timeIntervalSince1970: 2))
            ]
        )
    }

    func waitForBlockedSessionListRefresh() async {
        guard blockedListRefreshCount == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            guard blockedListRefreshCount == 0 else {
                continuation.resume()
                return
            }
            blockedListWaiters.append(continuation)
        }
    }

    func releaseBlockedSessionListRefresh() {
        blockedListContinuations.forEach { $0.resume(returning: page) }
        blockedListContinuations = []
    }

    private func notifyBlockedListWaiters() {
        blockedListWaiters.forEach { $0.resume() }
        blockedListWaiters = []
    }
}

private final class DelayedCommandActionClient: SessionStoreAPIClient {
    let projectsResult: [AgentProject]
    let sessionsResult: [AgentSession]
    let actionsByPath: [String: [AgentCommandAction]]
    let runResults: [String: Result<CommandActionRunResponse, Error>]
    var requestedCommandActionPaths: [String] = []
    var requestedCommandActionRuns: [RequestedCommandActionRun] = []
    private var runContinuations: [CheckedContinuation<CommandActionRunResponse, Error>] = []
    private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        projects: [AgentProject],
        sessions: [AgentSession],
        actionsByPath: [String: [AgentCommandAction]],
        runResults: [String: Result<CommandActionRunResponse, Error>]
    ) {
        self.projectsResult = projects
        self.sessionsResult = sessions
        self.actionsByPath = actionsByPath
        self.runResults = runResults
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        sessionsResult
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        []
    }

    func commandActions(path: String) async throws -> [AgentCommandAction] {
        requestedCommandActionPaths.append(path)
        return actionsByPath[path] ?? []
    }

    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse {
        requestedCommandActionRuns.append(RequestedCommandActionRun(path: path, id: id, confirmed: confirmed))
        return try await withCheckedThrowingContinuation { continuation in
            runContinuations.append(continuation)
            notifyRequestCountWaiters()
        }
    }

    func waitForRunRequestCount(_ count: Int) async {
        guard runContinuations.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            guard runContinuations.count < count else {
                continuation.resume()
                return
            }
            requestCountWaiters.append((count, continuation))
        }
    }

    func resolveRun(at index: Int) {
        guard runContinuations.indices.contains(index), requestedCommandActionRuns.indices.contains(index) else {
            return
        }
        let request = requestedCommandActionRuns[index]
        let key = "\(request.path)#\(request.id)"
        switch runResults[key] ?? .failure(MockError.unimplemented) {
        case .success(let response):
            runContinuations[index].resume(returning: response)
        case .failure(let error):
            runContinuations[index].resume(throwing: error)
        }
    }

    private func notifyRequestCountWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in requestCountWaiters {
            if runContinuations.count >= waiter.0 {
                waiter.1.resume()
            } else {
                pending.append(waiter)
            }
        }
        requestCountWaiters = pending
    }
}

private final class OrderedHistoryPageClient: SessionStoreAPIClient {
    let projectsResult: [AgentProject]
    let page: SessionsPage
    private let lock = NSLock()
    private var requestedMessageCursorsStorage: [String?] = []
    private var requestedMessageLimitsStorage: [Int?] = []
    private var requestedMessageLoadModesStorage: [HistoryMessagesPage.LoadMode] = []
    private var historyContinuations: [CheckedContinuation<HistoryMessagesPage, Error>?] = []
    private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(projects: [AgentProject], page: SessionsPage) {
        self.projectsResult = projects
        self.page = page
    }

    var requestedMessageCursors: [String?] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return requestedMessageCursorsStorage
    }

    var requestedMessageLimits: [Int?] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return requestedMessageLimitsStorage
    }

    var requestedMessageLoadModes: [HistoryMessagesPage.LoadMode] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return requestedMessageLoadModesStorage
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        page.sessions
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        page
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        let page = try await messagesPage(sessionID: sessionID, before: before, limit: limit)
        return page.messages
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        try await messagesPage(sessionID: sessionID, before: before, limit: limit, loadMode: .full)
    }

    func messagesPage(
        sessionID: String,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode
    ) async throws -> HistoryMessagesPage {
        try await withCheckedThrowingContinuation { continuation in
            let waiters = appendHistoryRequest(before: before, limit: limit, loadMode: loadMode, continuation: continuation)
            waiters.forEach { $0.resume() }
        }
    }

    func waitForHistoryRequestCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResumeNow = appendRequestCountWaiter(count: count, continuation: continuation)
            if shouldResumeNow {
                continuation.resume()
            }
        }
    }

    func resolveHistoryRequest(
        at index: Int,
        with page: HistoryMessagesPage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let continuation = takeHistoryContinuation(at: index) else {
            XCTFail("No pending history request at index \(index)", file: file, line: line)
            return
        }
        continuation.resume(returning: page)
    }

    func failHistoryRequest(
        at index: Int,
        with error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let continuation = takeHistoryContinuation(at: index) else {
            XCTFail("No pending history request at index \(index)", file: file, line: line)
            return
        }
        continuation.resume(throwing: error)
    }

    private func appendHistoryRequest(
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode,
        continuation: CheckedContinuation<HistoryMessagesPage, Error>
    ) -> [CheckedContinuation<Void, Never>] {
        lock.lock()
        defer {
            lock.unlock()
        }
        historyContinuations.append(continuation)
        requestedMessageCursorsStorage.append(before)
        requestedMessageLimitsStorage.append(limit)
        requestedMessageLoadModesStorage.append(loadMode)
        return takeReadyRequestCountWaitersLocked()
    }

    private func appendRequestCountWaiter(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    ) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard historyContinuations.count < count else {
            return true
        }
        requestCountWaiters.append((count, continuation))
        return false
    }

    private func takeHistoryContinuation(at index: Int) -> CheckedContinuation<HistoryMessagesPage, Error>? {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard historyContinuations.indices.contains(index) else {
            return nil
        }
        let continuation = historyContinuations[index]
        historyContinuations[index] = nil
        return continuation
    }

    private func takeReadyRequestCountWaitersLocked() -> [CheckedContinuation<Void, Never>] {
        var ready: [CheckedContinuation<Void, Never>] = []
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in requestCountWaiters {
            if historyContinuations.count >= waiter.0 {
                ready.append(waiter.1)
            } else {
                pending.append(waiter)
            }
        }
        requestCountWaiters = pending
        return ready
    }
}

private func queryValue(_ name: String, in url: URL?) -> String? {
    guard let url else {
        return nil
    }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first { $0.name == name }?
        .value
}

private func payloadContainsInlineImage(_ payload: CodexAppServerTurnPayload?) -> Bool {
    payload?.input.contains { item in
        if case .image(let url, _) = item {
            return url.trimmingCharacters(in: .whitespacesAndNewlines)
                .range(of: "data:image/", options: [.anchored, .caseInsensitive]) != nil
        }
        return false
    } ?? false
}

private func payloadContainsImageURL(_ payload: CodexAppServerTurnPayload?, url expectedURL: String) -> Bool {
    payload?.input.contains { item in
        if case .image(let url, _) = item {
            return url == expectedURL
        }
        return false
    } ?? false
}

private func payloadContainsMention(_ payload: CodexAppServerTurnPayload?, name expectedName: String) -> Bool {
    payload?.input.contains { item in
        if case .mention(let name, _) = item {
            return name == expectedName
        }
        return false
    } ?? false
}

private func payloadContainsSkill(_ payload: CodexAppServerTurnPayload?, name expectedName: String) -> Bool {
    payload?.input.contains { item in
        if case .skill(let name, _) = item {
            return name == expectedName
        }
        return false
    } ?? false
}

@MainActor
private func waitForConversationMessages(
    in store: ConversationStore,
    sessionID: SessionID,
    matching predicate: ([ConversationMessage]) -> Bool
) async throws -> [ConversationMessage] {
    for _ in 0..<300 {
        let messages = store.messages(for: sessionID)
        if predicate(messages) {
            return messages
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let messages = store.messages(for: sessionID)
    XCTFail("会话消息未在超时内达到预期，当前消息数：\(messages.count)")
    return messages
}

private func valuesOrTimeout(
    _ task: Task<[Int], Never>,
    expectedCount: Int,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async throws -> [Int] {
    try await withThrowingTaskGroup(of: [Int]?.self) { group in
        group.addTask {
            await task.value
        }
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            return nil
        }
        guard let result = try await group.next() else {
            task.cancel()
            return []
        }
        group.cancelAll()
        guard let values = result else {
            task.cancel()
            XCTFail("事件流在超时前未拿齐 \(expectedCount) 条")
            return []
        }
        if values.count < expectedCount {
            XCTFail("事件流数量不足：expected=\(expectedCount), actual=\(values.count)")
        }
        return values
    }
}

@MainActor
private func waitForWebSocketStatus(_ expected: WebSocketStatus, store: SessionStore) async throws {
    for _ in 0..<80 {
        if store.webSocketStatus == expected {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("WebSocket 状态未变为 \(expected)，当前为 \(store.webSocketStatus)")
}

@MainActor
private func waitForRuntimeActivity(
    in store: SessionStore,
    sessionID: SessionID,
    matching predicate: (RuntimeActivitySnapshot) -> Bool = { _ in true }
) async throws -> RuntimeActivitySnapshot {
    for _ in 0..<80 {
        if let snapshot = store.runtimeActivitySnapshot(for: sessionID), predicate(snapshot) {
            return snapshot
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("runtime activity snapshot 未在超时前更新")
    throw MockError.timeout
}

@MainActor
private func waitForRuntimeActivityCleared(in store: SessionStore, sessionID: SessionID) async throws {
    for _ in 0..<80 {
        if store.runtimeActivitySnapshot(for: sessionID) == nil {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("runtime activity snapshot 未在超时前清理")
}

@MainActor
private func waitForSelectedActiveTurnID(_ expected: TurnID?, store: SessionStore) async throws {
    for _ in 0..<80 {
        if store.selectedSession?.activeTurnID == expected {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("activeTurnID 未在超时前变为 \(expected ?? "nil")，当前为 \(store.selectedSession?.activeTurnID ?? "nil")")
}

@MainActor
private func waitForSelectedSessionStatus(_ expected: String, store: SessionStore) async throws {
    for _ in 0..<80 {
        if store.selectedSession?.status == expected {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("session status 未在超时前变为 \(expected)，当前为 \(store.selectedSession?.status ?? "nil")")
}

@MainActor
private func waitForSelectedThreadGoalStatus(_ expected: ThreadGoalStatus, store: SessionStore) async throws {
    for _ in 0..<80 {
        if store.selectedThreadGoal?.status == expected {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("目标状态未在超时前变为 \(expected.rawValue)，当前为 \(store.selectedThreadGoal?.status.rawValue ?? "nil")")
}

@MainActor
extension ConversationDataFlowTests {
    func testCodexAppServerConnectionMatchesResponsesByRequestID() async throws {
        let transport = FakeCodexAppServerTransport()
        let connection = CodexAppServerConnection(transport: transport, requestTimeout: 2)
        let connectTask = Task {
            try await connection.connect(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:7777/api/app-server/ws")), token: "test-token")
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)
        try await connectTask.value

        let connectedMessages = try await waitForFakeAppServerMessages(transport, count: 2)
        let initialized = try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: Data(connectedMessages[1].utf8)
        )
        XCTAssertEqual(initialized.method, "initialized")

        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [
            AgentProject(id: "proj_rpc", name: "RPC", path: "/tmp/rpc")
        ])
        let listTask = Task {
            try await connection.send(try builder.threadList(cwd: "/tmp/rpc", limit: 1))
        }
        let readTask = Task {
            try await connection.send(builder.threadRead(threadID: "thr_out_of_order"))
        }

        let sentMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let requests = try sentMessages.dropFirst(2).map(decodeAppServerRequest)
        let listRequest = try XCTUnwrap(requests.first { $0.method == "thread/list" })
        let readRequest = try XCTUnwrap(requests.first { $0.method == "thread/read" })

        transport.enqueue(#"{"id":\#(try jsonFragment(for: readRequest.id)),"result":{"name":"read-first"}}"#)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: listRequest.id)),"result":{"name":"list-second"}}"#)

        let listResult = try await listTask.value?.objectValue
        let readResult = try await readTask.value?.objectValue
        XCTAssertEqual(listResult?["name"]?.stringValue, "list-second")
        XCTAssertEqual(readResult?["name"]?.stringValue, "read-first")

        await connection.disconnect()
    }

    func testCodexAppServerConnectionRoutesNotificationsAndServerRequests() async throws {
        let connection = CodexAppServerConnection(transport: FakeCodexAppServerTransport(), requestTimeout: 2)
        let notificationStream = await connection.notifications()
        let serverRequestStream = await connection.serverRequests()
        var notificationIterator = notificationStream.makeAsyncIterator()
        var serverRequestIterator = serverRequestStream.makeAsyncIterator()

        await connection.ingestTextForTesting(#"{"method":"turn/started","params":{"threadId":"thr_stream","turn":{"id":"turn_stream"}}}"#)
        let notification = await notificationIterator.next()
        XCTAssertEqual(notification?.method, "turn/started")
        XCTAssertEqual(notification?.params?["threadId"]?.stringValue, "thr_stream")

        await connection.ingestTextForTesting(#"{"id":99,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_stream","turnId":"turn_stream","itemId":"cmd_1","command":"go test ./..."}}"#)
        let request = await serverRequestIterator.next()
        XCTAssertEqual(request?.id, .int(99))
        XCTAssertEqual(request?.method, "item/commandExecution/requestApproval")
        XCTAssertEqual(request?.params?["command"]?.stringValue, "go test ./...")
    }

    func testCodexAppServerConnectionBuffersInboundStreamsWithoutDroppingOldEvents() async throws {
        let connection = CodexAppServerConnection(transport: FakeCodexAppServerTransport(), requestTimeout: 2)
        let notificationStream = await connection.notifications()
        let serverRequestStream = await connection.serverRequests()

        for index in 0..<700 {
            await connection.ingestTextForTesting(#"{"method":"turn/probe","params":{"index":\#(index)}}"#)
        }
        for index in 0..<180 {
            await connection.ingestTextForTesting(#"{"id":\#(index + 1),"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_buffer","turnId":"turn_buffer","itemId":"cmd_\#(index)","index":\#(index)}}"#)
        }

        let notificationValuesTask = Task {
            var iterator = notificationStream.makeAsyncIterator()
            var values: [Int] = []
            for _ in 0..<700 {
                guard let item = await iterator.next() else {
                    break
                }
                values.append(item.params?["index"]?.intValue ?? -1)
            }
            return values
        }
        let requestValuesTask = Task {
            var iterator = serverRequestStream.makeAsyncIterator()
            var values: [Int] = []
            for _ in 0..<180 {
                guard let item = await iterator.next() else {
                    break
                }
                values.append(item.params?["index"]?.intValue ?? -1)
            }
            return values
        }

        let notificationValues = try await valuesOrTimeout(notificationValuesTask, expectedCount: 700)
        let requestValues = try await valuesOrTimeout(requestValuesTask, expectedCount: 180)

        XCTAssertEqual(notificationValues.count, 700)
        XCTAssertEqual(notificationValues.first, 0)
        XCTAssertEqual(notificationValues.last, 699)
        XCTAssertEqual(requestValues.count, 180)
        XCTAssertEqual(requestValues.first, 0)
        XCTAssertEqual(requestValues.last, 179)
    }

    func testCodexAppServerConnectionMapsAppServerErrors() async throws {
        let transport = FakeCodexAppServerTransport()
        let connection = CodexAppServerConnection(transport: transport, requestTimeout: 2)
        try await connectFakeAppServer(connection, transport: transport)

        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [
            AgentProject(id: "proj_error", name: "Error", path: "/tmp/error")
        ])
        let requestTask = Task {
            try await connection.send(try builder.threadList(cwd: "/tmp/error", limit: 1))
        }

        let sentMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let request = try decodeAppServerRequest(sentMessages[2])
        XCTAssertEqual(request.method, "thread/list")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: request.id)),"error":{"code":-32000,"message":"Not initialized"}}"#)

        do {
            _ = try await requestTask.value
            XCTFail("Expected app-server error")
        } catch CodexAppServerConnectionError.appServer(let error) {
            XCTAssertEqual(error.code, -32000)
            XCTAssertEqual(error.message, "Not initialized")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await connection.disconnect()
    }

    func testCodexAppServerConnectionSkipsMalformedFrameWithoutFailingPendingRequests() async throws {
        let transport = FakeCodexAppServerTransport()
        let connection = CodexAppServerConnection(transport: transport, requestTimeout: 2)
        try await connectFakeAppServer(connection, transport: transport)

        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [
            AgentProject(id: "proj_bad_frame", name: "Bad Frame", path: "/tmp/bad-frame")
        ])
        let requestTask = Task {
            try await connection.send(try builder.threadList(cwd: "/tmp/bad-frame", limit: 1))
        }

        let sentMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let request = try decodeAppServerRequest(sentMessages[2])
        XCTAssertEqual(request.method, "thread/list")

        transport.enqueue(#"{"id": "#)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: request.id)),"result":{"name":"still-ok"}}"#)

        let result = try await requestTask.value?.objectValue
        XCTAssertEqual(result?["name"]?.stringValue, "still-ok")

        await connection.disconnect()
    }

    func testCodexAppServerFakeSmokeCoversThreadTurnAndApproval() async throws {
        let transport = FakeCodexAppServerTransport()
        let connection = CodexAppServerConnection(transport: transport, requestTimeout: 2)
        let notificationStream = await connection.notifications()
        let serverRequestStream = await connection.serverRequests()
        var notificationIterator = notificationStream.makeAsyncIterator()
        var serverRequestIterator = serverRequestStream.makeAsyncIterator()
        var projector = CodexAppServerEventProjector()

        try await connectFakeAppServer(connection, transport: transport)

        let project = AgentProject(id: "proj_smoke", name: "Smoke", path: "/tmp/smoke")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])
        let threadTask = Task {
            try await connection.send(builder.threadStart(projectID: project.id))
        }

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thread-smoke","title":"Smoke"}}}"#)
        _ = try await threadTask.value

        transport.enqueue(#"{"method":"thread/started","params":{"thread":{"id":"thread-smoke","title":"Smoke","cwd":"/tmp/smoke"}}}"#)
        let threadStarted = await notificationIterator.next()
        XCTAssertEqual(threadStarted?.method, "thread/started")
        XCTAssertEqual(threadStarted?.params?["thread"]?.objectValue?["id"]?.stringValue, "thread-smoke")

        let turnTask = Task {
            try await connection.send(builder.turnStart(
                threadID: "thread-smoke",
                projectID: project.id,
                prompt: "帮我验收",
                clientMessageID: "client-smoke"
            ))
        }

        let turnMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let turnStart = try decodeAppServerRequest(turnMessages[3])
        XCTAssertEqual(turnStart.method, "turn/start")
        let turnParams = try XCTUnwrap(turnStart.params?.objectValue)
        XCTAssertEqual(turnParams["threadId"]?.stringValue, "thread-smoke")
        XCTAssertEqual(turnParams["approvalPolicy"]?.stringValue, "on-request")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: turnStart.id)),"result":{"turn":{"id":"turn-smoke","status":"inProgress"}}}"#)
        _ = try await turnTask.value

        transport.enqueue(#"{"method":"turn/started","params":{"threadId":"thread-smoke","turn":{"id":"turn-smoke"}}}"#)
        let nextNotification = await notificationIterator.next()
        let turnStarted = try XCTUnwrap(nextNotification)
        if case .turnStarted(let meta) = try XCTUnwrap(projector.project(turnStarted)) {
            XCTAssertEqual(meta.sessionID, "thread-smoke")
            XCTAssertEqual(meta.turnID, "turn-smoke")
        } else {
            XCTFail("Expected turnStarted")
        }

        transport.enqueue(#"{"id":77,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread-smoke","turnId":"turn-smoke","itemId":"cmd-smoke","command":"go test ./...","reason":"验收直连链路"}}"#)
        let nextServerRequest = await serverRequestIterator.next()
        let approvalRequest = try XCTUnwrap(nextServerRequest)
        if case .approvalRequest(let approval, let meta) = try XCTUnwrap(projector.project(approvalRequest)) {
            XCTAssertEqual(meta.sessionID, "thread-smoke")
            XCTAssertEqual(approval.id, "cmd-smoke")
            XCTAssertEqual(approval.kind, "command")
            XCTAssertTrue(approval.body?.contains("验收直连链路") == true)
        } else {
            XCTFail("Expected approvalRequest")
        }

        await connection.disconnect()
    }

    func testCodexAppServerSessionRuntimeDrivesDirectClientAndSocket() async throws {
        let project = AgentProject(id: "proj_direct", name: "Direct", path: "/tmp/direct")
        let config = CodexAppServerConfigResponse(
            gatewayWSURL: "ws://127.0.0.1:7777/api/app-server/ws",
            runtime: CodexAppServerRuntimeMetadata(
                type: "codex_app_server",
                transport: "ws",
                managed: true,
                gatewayAvailable: true,
                upstreamConfigured: true,
                running: true,
                initialized: false,
                pendingRequests: 0
            ),
            projects: [project],
            policy: CodexAppServerPolicyMetadata(
                allowedMethods: ["initialize", "initialized", "thread/start", "turn/start"],
                projectsSource: "agentd_allowlist"
            )
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { config }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "帮我验收",
                resumeID: "",
                clientMessageID: "client_direct_1"
            ))
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_direct","sessionId":"thr_direct","preview":"帮我验收","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"直连验收","turns":[]}}}"#)

        let turnMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let firstTurnStart = try decodeAppServerRequest(turnMessages[3])
        XCTAssertEqual(firstTurnStart.method, "turn/start")
        let firstTurnParams = try XCTUnwrap(firstTurnStart.params?.objectValue)
        XCTAssertEqual(firstTurnParams["threadId"]?.stringValue, "thr_direct")
        XCTAssertEqual(firstTurnParams["cwd"]?.stringValue, project.path)
        XCTAssertEqual(firstTurnParams["clientUserMessageId"]?.stringValue, "client_direct_1")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: firstTurnStart.id)),"result":{"turn":{"id":"turn_direct_1","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490002,"completedAt":null,"durationMs":null}}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.id, "thr_direct")
        XCTAssertEqual(created.session.status, "running")
        XCTAssertEqual(created.session.activeTurnID, "turn_direct_1")
        let createdContext = try XCTUnwrap(created.session.context)
        XCTAssertEqual(createdContext.status?.type, "active")
        XCTAssertEqual(createdContext.environment?.cwd, project.path)
        XCTAssertEqual(createdContext.environment?.provider, "openai")
        XCTAssertTrue(createdContext.sources.contains { $0.label == "appServer" })
        XCTAssertEqual(try CodexAppServerSessionRuntime.gatewayURL(endpoint: "http://127.0.0.1:8787", sessionID: "thr_direct").path, "/api/app-server/ws")

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }
        socket.connect(sessionID: "thr_direct")

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        transport.enqueue(#"{"method":"item/agentMessage/delta","params":{"threadId":"thr_direct","turnId":"turn_direct_1","itemId":"assistant_1","delta":"收到"}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .assistantDelta(let delta, _) = $0 {
                return delta.text == "收到"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .assistantDelta(let delta, _) = $0 {
                return delta.text == "收到"
            }
            return false
        })

        XCTAssertTrue(socket.sendInput("继续\r", clientMessageID: "client_direct_2"))
        let followUpTurnStart = try await waitForFakeAppServerRequest(transport, method: "turn/start", after: 4)
        XCTAssertEqual(followUpTurnStart.method, "turn/start")
        let followUpParams = try XCTUnwrap(followUpTurnStart.params?.objectValue)
        XCTAssertEqual(followUpParams["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "继续")
        XCTAssertEqual(followUpParams["clientUserMessageId"]?.stringValue, "client_direct_2")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: followUpTurnStart.id)),"result":{"turn":{"id":"turn_direct_2","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490003,"completedAt":null,"durationMs":null}}}"#)

        transport.enqueue(#"{"id":99,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_direct","turnId":"turn_direct_2","itemId":"cmd_direct","command":"go test ./..."}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .approvalRequest(let approval, _) = $0 {
                return approval.id == "cmd_direct"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(socket.sendApprovalDecision(approvalID: "cmd_direct", decision: "accept", message: nil))
        let approvalResponse = try await waitForFakeAppServerResponse(transport, id: .int(99))
        XCTAssertEqual(approvalResponse.id, .int(99))
        XCTAssertEqual(approvalResponse.result?["decision"]?.stringValue, "accept")

        transport.enqueue(#"{"id":100,"method":"item/permissions/requestApproval","params":{"threadId":"thr_direct","turnId":"turn_direct_2","itemId":"perm_direct","permissions":{"sandbox":"danger-full-access","networkAccess":true}}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .approvalRequest(let approval, _) = $0 {
                return approval.id == "perm_direct"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(socket.sendApprovalDecision(approvalID: "perm_direct", decision: "accept", message: nil))
        let permissionsResponse = try await waitForFakeAppServerResponse(transport, id: .int(100))
        XCTAssertEqual(permissionsResponse.id, .int(100))
        XCTAssertEqual(permissionsResponse.result?["permissions"]?.objectValue?.isEmpty, true)
        XCTAssertEqual(permissionsResponse.result?["scope"]?.stringValue, "turn")
        XCTAssertEqual(permissionsResponse.result?["strictAutoReview"]?.boolValue, true)
        XCTAssertNil(permissionsResponse.result?["decision"])

        socket.disconnect()
    }

    func testRuntimeCreateSessionKeepsModelOnTurnOnly() async throws {
        let project = AgentProject(id: "proj_thread_model_guard", name: "Thread Model Guard", path: "/tmp/thread-model-guard")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)
        var options = CodexAppServerTurnOptions.default
        options.model = "gpt-selected"
        options.modelProvider = "openai"

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "模型只属于 turn",
                input: [.text("模型只属于 turn")],
                turnOptions: options,
                resumeID: "",
                clientMessageID: "client_thread_model_guard"
            ))
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let threadStart = try await waitForFakeAppServerRequest(transport, method: "thread/start", after: 1)
        let threadParams = try XCTUnwrap(threadStart.params?.objectValue)
        XCTAssertNil(threadParams["model"], "thread/start 不应携带 model，避免回归旧 app-server 校验问题")
        XCTAssertNil(threadParams["modelProvider"])
        transportResponse(transport, id: threadStart.id, result: #"{"thread":{"id":"thr_thread_model_guard","sessionId":"thr_thread_model_guard","preview":"模型只属于 turn","ephemeral":false,"createdAt":1780491000,"updatedAt":1780491001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/thread-model-guard","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"模型只属于 turn","turns":[]}}"#)

        let turnStart = try await waitForFakeAppServerRequest(transport, method: "turn/start", after: 3)
        let turnParams = try XCTUnwrap(turnStart.params?.objectValue)
        XCTAssertEqual(turnParams["model"]?.stringValue, "gpt-selected")
        XCTAssertNil(turnParams["modelProvider"])
        transportResponse(transport, id: turnStart.id, result: #"{"turn":{"id":"turn_thread_model_guard","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780491002,"completedAt":null,"durationMs":null}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.id, "thr_thread_model_guard")
        XCTAssertEqual(created.session.activeTurnID, "turn_thread_model_guard")
    }

    func testDirectRuntimeBackfillsActiveTurnFromDeltaBeforeGuidance() async throws {
        let project = AgentProject(id: "proj_delta_guidance", name: "Delta Guidance", path: "/tmp/delta-guidance")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let listTask = Task {
            try await client.sessions(projectID: project.id, cursor: nil, limit: nil)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        assertInitializeEnablesExperimentalAPI(initialize)
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let threadList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: threadList.id, result: #"{"data":[{"id":"thr_delta_guidance","sessionId":"thr_delta_guidance","preview":"delta 回填","ephemeral":false,"modelProvider":"openai","createdAt":1780490900,"updatedAt":1780490901,"status":{"type":"idle"},"path":null,"cwd":"/tmp/delta-guidance","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"delta 回填","turns":[]}],"nextCursor":null}"#)
        _ = try await listTask.value

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }
        socket.connect(sessionID: "thr_delta_guidance")

        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 3)
        transportResponse(transport, id: resume.id, result: #"{"thread":{"id":"thr_delta_guidance","sessionId":"thr_delta_guidance","preview":"delta 回填","ephemeral":false,"modelProvider":"openai","createdAt":1780490900,"updatedAt":1780490902,"status":{"type":"idle"},"path":null,"cwd":"/tmp/delta-guidance","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"delta 回填","turns":[]}}"#)

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        // 模拟重连后漏掉 turn/started，但先收到带 turnId 的流式输出。
        // UI reducer 已经会开放“引导当前回复”，runtime 自己的 context 也必须同步回填，否则 steerTurn 会误拒发。
        transport.enqueue(#"{"method":"item/agentMessage/delta","params":{"threadId":"thr_delta_guidance","turnId":"turn_delta_guidance","itemId":"assistant_delta_guidance","delta":"正在继续"}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .assistantDelta(let delta, _) = $0 {
                return delta.text == "正在继续"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .assistantDelta(let delta, _) = $0 {
                return delta.text == "正在继续"
            }
            return false
        })

        XCTAssertTrue(socket.sendGuidance(
            CodexAppServerTurnPayload(prompt: "沿着当前回复继续"),
            clientMessageID: "client_delta_guidance",
            expectedTurnID: "turn_delta_guidance"
        ))
        let steer = try await waitForFakeAppServerRequest(transport, method: "turn/steer", after: 4)
        let steerParams = try XCTUnwrap(steer.params?.objectValue)
        XCTAssertEqual(steerParams["threadId"]?.stringValue, "thr_delta_guidance")
        XCTAssertEqual(steerParams["expectedTurnId"]?.stringValue, "turn_delta_guidance")
        XCTAssertEqual(steerParams["clientUserMessageId"]?.stringValue, "client_delta_guidance")
        XCTAssertEqual(steerParams["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "沿着当前回复继续")
        transportResponse(transport, id: steer.id, result: #"{}"#)

        socket.disconnect()
    }

    func testDirectRuntimeRetriesModelListAfterStaleInitializationError() async throws {
        let project = AgentProject(id: "proj_stale_model", name: "Stale Model", path: "/tmp/stale-model")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        let modelsTask = Task {
            try await runtime.modelOptions()
        }

        let firstTransport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let firstInitializeMessages = try await waitForFakeAppServerMessages(firstTransport, count: 1)
        let firstInitialize = try decodeAppServerRequest(firstInitializeMessages[0])
        assertInitializeEnablesExperimentalAPI(firstInitialize)
        transportResponse(firstTransport, id: firstInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let staleModelList = try await waitForFakeAppServerRequest(firstTransport, method: "model/list", after: 1)
        // 旧 gateway/upstream 状态会把已初始化连接误判为未初始化；客户端应重连并重试一次。
        transportErrorResponse(firstTransport, id: staleModelList.id, code: -32600, message: "Not initialized")

        let secondTransport = try await waitForFakeAppServerTransport(in: pool, index: 1)
        let secondInitializeMessages = try await waitForFakeAppServerMessages(secondTransport, count: 1)
        let secondInitialize = try decodeAppServerRequest(secondInitializeMessages[0])
        assertInitializeEnablesExperimentalAPI(secondInitialize)
        transportResponse(secondTransport, id: secondInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let retryModelList = try await waitForFakeAppServerRequest(secondTransport, method: "model/list", after: 1)
        transportResponse(secondTransport, id: retryModelList.id, result: #"{"models":[{"id":"gpt-stale-default","title":"Stale Default","provider":"openai","isDefault":true},{"id":"gpt-side"}]}"#)

        let options = try await modelsTask.value
        XCTAssertEqual(options.first?.model, "gpt-stale-default")
        XCTAssertEqual(options.first?.provider, "openai")
        XCTAssertEqual(options.first?.isDefault, true)
    }

    func testMultiRuntimeModelOptionsKeepCodexWhenClaudeFails() async throws {
        let project = AgentProject(id: "proj_multi_models", name: "Multi Models", path: "/tmp/multi-models")
        let config = makeDirectAppServerConfig(project: project, channels: [makeClaudeChannelMetadata()])
        let codexTransport = FakeCodexAppServerTransport()
        let claudeTransport = FakeCodexAppServerTransport()
        let codex = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "codex",
            transportFactory: { codexTransport },
            configProvider: { config }
        )
        let claude = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "claude",
            transportFactory: { claudeTransport },
            configProvider: { config }
        )
        let client = MultiRuntimeSessionAPIClient(codexRuntime: codex, claudeRuntime: claude)

        let modelTask = Task { try await client.modelOptions() }
        let codexInitialize = try await waitForFakeAppServerRequest(codexTransport, method: "initialize")
        transportResponse(codexTransport, id: codexInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let codexModelList = try await waitForFakeAppServerRequest(codexTransport, method: "model/list", after: 1)
        transportResponse(codexTransport, id: codexModelList.id, result: #"{"models":[{"id":"gpt-live","title":"GPT Live","provider":"openai","isDefault":true}]}"#)

        let claudeInitialize = try await waitForFakeAppServerRequest(claudeTransport, method: "initialize")
        transportResponse(claudeTransport, id: claudeInitialize.id, result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#)
        let claudeModelList = try await waitForFakeAppServerRequest(claudeTransport, method: "model/list", after: 1)
        transportErrorResponse(claudeTransport, id: claudeModelList.id, code: -32000, message: "Claude CLI not logged in")

        let options = try await modelTask.value
        XCTAssertEqual(options.map(\.model), ["gpt-live"])
        XCTAssertEqual(options.first?.runtimeProvider, "codex")
    }

    func testMultiRuntimeCompositeCursorCarriesBuffersAndContinuesRuntimeCursors() async throws {
        let project = AgentProject(id: "proj_multi_cursor", name: "Multi Cursor", path: "/tmp/multi-cursor")
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
        let codexFirstParams = try XCTUnwrap(codexFirstList.params?.objectValue)
        XCTAssertNil(codexFirstParams["cursor"]?.stringValue)
        XCTAssertEqual(codexFirstParams["limit"]?.intValue, 2)
        transportResponse(codexTransport, id: codexFirstList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "codex-new", cwd: project.path, source: "appServer", updatedAt: 1780493000),
            appServerThreadJSON(id: "codex-buffer", cwd: project.path, source: "appServer", updatedAt: 1780491000)
        ], nextCursor: "codex-next"))

        let claudeInitialize = try await waitForFakeAppServerRequest(claudeTransport, method: "initialize")
        transportResponse(claudeTransport, id: claudeInitialize.id, result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#)
        let claudeFirstList = try await waitForFakeAppServerRequest(claudeTransport, method: "thread/list", after: 1)
        transportResponse(claudeTransport, id: claudeFirstList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "claude-new", cwd: project.path, source: "claude", updatedAt: 1780492000),
            appServerThreadJSON(id: "claude-buffer", cwd: project.path, source: "claude", updatedAt: 1780490000)
        ], nextCursor: "claude-next"))

        let firstPage = try await firstTask.value
        XCTAssertEqual(firstPage.sessions.map(\.id), ["codex-new", "claude-new"])
        let firstCursor = try XCTUnwrap(firstPage.nextCursor)

        // 第二页来自 composite cursor 中的 buffer，不应重复请求任一 runtime。
        let codexMessageCount = (await codexTransport.sentMessages()).count
        let claudeMessageCount = (await claudeTransport.sentMessages()).count
        let secondPage = try await client.sessionsPage(projectID: project.id, cursor: firstCursor, limit: 2)
        XCTAssertEqual(secondPage.sessions.map(\.id), ["codex-buffer", "claude-buffer"])
        let codexMessageCountAfterBuffer = (await codexTransport.sentMessages()).count
        let claudeMessageCountAfterBuffer = (await claudeTransport.sentMessages()).count
        XCTAssertEqual(codexMessageCountAfterBuffer, codexMessageCount)
        XCTAssertEqual(claudeMessageCountAfterBuffer, claudeMessageCount)
        let secondCursor = try XCTUnwrap(secondPage.nextCursor)

        let thirdTask = Task { try await client.sessionsPage(projectID: project.id, cursor: secondCursor, limit: 2) }
        let codexSecondList = try await waitForFakeAppServerRequest(codexTransport, method: "thread/list", after: codexMessageCount)
        let codexSecondParams = try XCTUnwrap(codexSecondList.params?.objectValue)
        XCTAssertEqual(codexSecondParams["cursor"]?.stringValue, "codex-next")
        transportResponse(codexTransport, id: codexSecondList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "codex-old", cwd: project.path, source: "appServer", updatedAt: 1780489000)
        ], nextCursor: nil))

        let claudeSecondList = try await waitForFakeAppServerRequest(claudeTransport, method: "thread/list", after: claudeMessageCount)
        let claudeSecondParams = try XCTUnwrap(claudeSecondList.params?.objectValue)
        XCTAssertEqual(claudeSecondParams["cursor"]?.stringValue, "claude-next")
        transportResponse(claudeTransport, id: claudeSecondList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "claude-old", cwd: project.path, source: "claude", updatedAt: 1780488000)
        ], nextCursor: nil))

        let thirdPage = try await thirdTask.value
        XCTAssertEqual(thirdPage.sessions.map(\.id), ["codex-old", "claude-old"])
        XCTAssertFalse(thirdPage.hasMore)
        XCTAssertNil(thirdPage.nextCursor)
    }

    func testDirectRuntimeRetriesNewSessionAfterStaleInitializationError() async throws {
        let project = AgentProject(id: "proj_stale_init_new", name: "Stale Init New", path: "/tmp/stale-init-new")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "恢复发送",
                resumeID: "",
                clientMessageID: "client_stale_new"
            ))
        }

        let firstTransport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let firstInitializeMessages = try await waitForFakeAppServerMessages(firstTransport, count: 1)
        let firstInitialize = try decodeAppServerRequest(firstInitializeMessages[0])
        assertInitializeEnablesExperimentalAPI(firstInitialize)
        transportResponse(firstTransport, id: firstInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let firstThreadMessages = try await waitForFakeAppServerMessages(firstTransport, count: 3)
        let staleThreadStart = try decodeAppServerRequest(firstThreadMessages[2])
        XCTAssertEqual(staleThreadStart.method, "thread/start")
        // app-server 上游重启后可能对旧连接返回 Not initialized；这里应重建连接而不是把用户发送直接标失败。
        transportErrorResponse(firstTransport, id: staleThreadStart.id, code: -32600, message: "Not initialized")

        let secondTransport = try await waitForFakeAppServerTransport(in: pool, index: 1)
        let secondInitializeMessages = try await waitForFakeAppServerMessages(secondTransport, count: 1)
        let secondInitialize = try decodeAppServerRequest(secondInitializeMessages[0])
        assertInitializeEnablesExperimentalAPI(secondInitialize)
        transportResponse(secondTransport, id: secondInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let secondThreadMessages = try await waitForFakeAppServerMessages(secondTransport, count: 3)
        let threadStart = try decodeAppServerRequest(secondThreadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        transportResponse(secondTransport, id: threadStart.id, result: #"{"thread":{"id":"thr_stale_new","sessionId":"thr_stale_new","preview":"恢复发送","ephemeral":false,"modelProvider":"openai","createdAt":1780490800,"updatedAt":1780490801,"status":{"type":"idle"},"path":null,"cwd":"/tmp/stale-init-new","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"恢复发送","turns":[]}}"#)

        let turnStart = try await waitForFakeAppServerRequest(secondTransport, method: "turn/start", after: 3)
        XCTAssertEqual(turnStart.params?.objectValue?["threadId"]?.stringValue, "thr_stale_new")
        XCTAssertEqual(turnStart.params?.objectValue?["clientUserMessageId"]?.stringValue, "client_stale_new")
        transportResponse(secondTransport, id: turnStart.id, result: #"{"turn":{"id":"turn_stale_new","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490802,"completedAt":null,"durationMs":null}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.id, "thr_stale_new")
        XCTAssertEqual(created.session.activeTurnID, "turn_stale_new")
    }

    func testDirectRuntimeRetriesGoalSetAfterStaleInitializationError() async throws {
        let project = AgentProject(id: "proj_stale_goal", name: "Stale Goal", path: "/tmp/stale-goal")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "",
                input: [],
                resumeID: "",
                clientMessageID: nil
            ))
        }

        let firstTransport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let initializeMessages = try await waitForFakeAppServerMessages(firstTransport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transportResponse(firstTransport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let threadMessages = try await waitForFakeAppServerMessages(firstTransport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        transportResponse(firstTransport, id: threadStart.id, result: #"{"thread":{"id":"thr_stale_goal","sessionId":"thr_stale_goal","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":1780490810,"updatedAt":1780490811,"status":{"type":"idle"},"path":null,"cwd":"/tmp/stale-goal","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"目标恢复","turns":[]}}"#)
        _ = try await createTask.value

        let goalTask = Task {
            try await runtime.setThreadGoal(threadID: "thr_stale_goal", objective: "恢复目标", status: .active)
        }
        let staleGoalSet = try await waitForFakeAppServerRequest(firstTransport, method: "thread/goal/set", after: 3)
        transportErrorResponse(firstTransport, id: staleGoalSet.id, code: -32600, message: "Not initialized")

        let secondTransport = try await waitForFakeAppServerTransport(in: pool, index: 1)
        let secondInitializeMessages = try await waitForFakeAppServerMessages(secondTransport, count: 1)
        let secondInitialize = try decodeAppServerRequest(secondInitializeMessages[0])
        assertInitializeEnablesExperimentalAPI(secondInitialize)
        transportResponse(secondTransport, id: secondInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let goalSet = try await waitForFakeAppServerRequest(secondTransport, method: "thread/goal/set", after: 1)
        XCTAssertEqual(goalSet.params?.objectValue?["threadId"]?.stringValue, "thr_stale_goal")
        XCTAssertEqual(goalSet.params?.objectValue?["objective"]?.stringValue, "恢复目标")
        transportResponse(secondTransport, id: goalSet.id, result: #"{"goal":{"threadId":"thr_stale_goal","objective":"恢复目标","status":"active","tokenBudget":null,"tokensUsed":0,"timeUsedSeconds":0,"createdAt":1780490812,"updatedAt":1780490812}}"#)

        let goal = try await goalTask.value
        XCTAssertEqual(goal.threadID, "thr_stale_goal")
        XCTAssertEqual(goal.objective, "恢复目标")
        XCTAssertEqual(goal.status, .active)
    }

    func testDirectRuntimeRetriesQueuedTurnStartAfterStaleInitializationError() async throws {
        let project = AgentProject(id: "proj_stale_turn", name: "Stale Turn", path: "/tmp/stale-turn")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        let listTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: nil)
        }
        let firstTransport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let initializeMessages = try await waitForFakeAppServerMessages(firstTransport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transportResponse(firstTransport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let threadList = try await waitForFakeAppServerRequest(firstTransport, method: "thread/list", after: 1)
        XCTAssertEqual(threadList.params?.objectValue?["cwd"]?.stringValue, project.path)
        transportResponse(firstTransport, id: threadList.id, result: #"{"data":[{"id":"thr_stale_turn","sessionId":"thr_stale_turn","preview":"可恢复 turn","ephemeral":false,"modelProvider":"openai","createdAt":1780490820,"updatedAt":1780490821,"status":{"type":"idle"},"path":null,"cwd":"/tmp/stale-turn","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"恢复 turn","turns":[]}],"nextCursor":null}"#)
        let page = try await listTask.value
        XCTAssertEqual(page.sessions.first?.id, "thr_stale_turn")

        let startTask = Task {
            try await runtime.startTurn(
                sessionID: "thr_stale_turn",
                payload: CodexAppServerTurnPayload(prompt: "旧连接后继续"),
                clientMessageID: "client_stale_turn"
            )
        }
        let beforeResumeMessages = await firstTransport.sentMessages()
        let firstResume = try await waitForFakeAppServerRequest(firstTransport, method: "thread/resume", after: beforeResumeMessages.count)
        XCTAssertEqual(firstResume.params?.objectValue?["threadId"]?.stringValue, "thr_stale_turn")
        transportResponse(firstTransport, id: firstResume.id, result: #"{"thread":{"id":"thr_stale_turn","sessionId":"thr_stale_turn","preview":"可恢复 turn","ephemeral":false,"modelProvider":"openai","createdAt":1780490820,"updatedAt":1780490822,"status":{"type":"idle"},"path":null,"cwd":"/tmp/stale-turn","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"恢复 turn","turns":[]}}"#)

        let beforeTurnMessages = await firstTransport.sentMessages()
        let staleTurnStart = try await waitForFakeAppServerRequest(firstTransport, method: "turn/start", after: beforeTurnMessages.count)
        XCTAssertEqual(staleTurnStart.params?.objectValue?["clientUserMessageId"]?.stringValue, "client_stale_turn")
        transportErrorResponse(firstTransport, id: staleTurnStart.id, code: -32600, message: "Not initialized")

        let secondTransport = try await waitForFakeAppServerTransport(in: pool, index: 1)
        let secondInitializeMessages = try await waitForFakeAppServerMessages(secondTransport, count: 1)
        let secondInitialize = try decodeAppServerRequest(secondInitializeMessages[0])
        assertInitializeEnablesExperimentalAPI(secondInitialize)
        transportResponse(secondTransport, id: secondInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        // 新连接必须重新 thread/resume，然后再发同一个 turn/start；否则 app-server 仍会认为线程未绑定。
        let secondResume = try await waitForFakeAppServerRequest(secondTransport, method: "thread/resume", after: 1)
        XCTAssertEqual(secondResume.params?.objectValue?["threadId"]?.stringValue, "thr_stale_turn")
        transportResponse(secondTransport, id: secondResume.id, result: #"{"thread":{"id":"thr_stale_turn","sessionId":"thr_stale_turn","preview":"可恢复 turn","ephemeral":false,"modelProvider":"openai","createdAt":1780490820,"updatedAt":1780490823,"status":{"type":"idle"},"path":null,"cwd":"/tmp/stale-turn","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"恢复 turn","turns":[]}}"#)

        let retryTurnStart = try await waitForFakeAppServerRequest(secondTransport, method: "turn/start", after: 2)
        let retryParams = try XCTUnwrap(retryTurnStart.params?.objectValue)
        XCTAssertEqual(retryParams["threadId"]?.stringValue, "thr_stale_turn")
        XCTAssertEqual(retryParams["clientUserMessageId"]?.stringValue, "client_stale_turn")
        XCTAssertEqual(retryParams["collaborationMode"]?.objectValue?["mode"]?.stringValue, "default")
        transportResponse(secondTransport, id: retryTurnStart.id, result: #"{"turn":{"id":"turn_stale_turn","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490824,"completedAt":null,"durationMs":null}}"#)

        let turnID = try await startTask.value
        XCTAssertEqual(turnID, "turn_stale_turn")
    }

    func testDirectRuntimeDoesNotRetryNonStaleInvalidRequestError() async throws {
        let project = AgentProject(id: "proj_invalid_32600", name: "Invalid 32600", path: "/tmp/invalid-32600")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "非法请求不应重试",
                resumeID: "",
                clientMessageID: "client_invalid_32600"
            ))
        }
        let firstTransport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let initializeMessages = try await waitForFakeAppServerMessages(firstTransport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transportResponse(firstTransport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let threadStart = try await waitForFakeAppServerRequest(firstTransport, method: "thread/start", after: 1)
        transportErrorResponse(firstTransport, id: threadStart.id, code: -32600, message: "Invalid request: collaborationMode.mode")

        do {
            _ = try await createTask.value
            XCTFail("非 Not initialized 的 -32600 应直接暴露协议错误")
        } catch let error as CodexAppServerConnectionError {
            guard case .appServer(let appServerError) = error else {
                XCTFail("应保留 app-server 错误类型，got \(error)")
                return
            }
            XCTAssertEqual(appServerError.code, -32600)
            XCTAssertEqual(appServerError.message, "Invalid request: collaborationMode.mode")
        }
        // 只有 Not initialized 才允许自动重建连接；协议错误重试会掩盖真正的 payload bug。
        XCTAssertNil(pool.transport(at: 1))
    }

    func testDirectRuntimeDoesNotRetryNoRolloutFoundAppServerError() async throws {
        let project = AgentProject(id: "proj_no_rollout_direct", name: "No Rollout Direct", path: "/tmp/no-rollout-direct")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        let listTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: nil)
        }
        let transport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let threadList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: threadList.id, result: #"{"data":[{"id":"thr_no_rollout","sessionId":"thr_no_rollout","preview":"缺失 rollout","ephemeral":false,"modelProvider":"openai","createdAt":1780490830,"updatedAt":1780490831,"status":{"type":"idle"},"path":null,"cwd":"/tmp/no-rollout-direct","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"缺失 rollout","turns":[]}],"nextCursor":null}"#)
        _ = try await listTask.value

        let startTask = Task {
            try await runtime.startTurn(
                sessionID: "thr_no_rollout",
                payload: CodexAppServerTurnPayload(prompt: "继续"),
                clientMessageID: "client_no_rollout"
            )
        }
        let beforeResumeMessages = await transport.sentMessages()
        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: beforeResumeMessages.count)
        transportResponse(transport, id: resume.id, result: #"{"thread":{"id":"thr_no_rollout","sessionId":"thr_no_rollout","preview":"缺失 rollout","ephemeral":false,"modelProvider":"openai","createdAt":1780490830,"updatedAt":1780490832,"status":{"type":"idle"},"path":null,"cwd":"/tmp/no-rollout-direct","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"缺失 rollout","turns":[]}}"#)

        let beforeTurnMessages = await transport.sentMessages()
        let turnStart = try await waitForFakeAppServerRequest(transport, method: "turn/start", after: beforeTurnMessages.count)
        transportErrorResponse(transport, id: turnStart.id, code: -32000, message: "no rollout found")

        do {
            _ = try await startTask.value
            XCTFail("no rollout found 是上游业务状态错误，不应被当成 stale initialize 自动重试")
        } catch let error as CodexAppServerConnectionError {
            guard case .appServer(let appServerError) = error else {
                XCTFail("应保留 app-server 错误类型，got \(error)")
                return
            }
            XCTAssertEqual(appServerError.code, -32000)
            XCTAssertEqual(appServerError.message, "no rollout found")
        }
        XCTAssertNil(pool.transport(at: 1))
    }

    func testEmptyNewDirectSessionResumesBeforeFirstFollowUpTurn() async throws {
        let project = AgentProject(id: "proj_empty_direct", name: "Empty Direct", path: "/tmp/empty-direct")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "",
                input: [],
                resumeID: "",
                clientMessageID: nil
            ))
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_empty_direct","sessionId":"thr_empty_direct","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":1780490600,"updatedAt":1780490601,"status":{"type":"idle"},"path":null,"cwd":"/tmp/empty-direct","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"空会话","turns":[]}}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.id, "thr_empty_direct")

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        socket.onStatus = { statuses.append($0) }
        socket.connect(sessionID: "thr_empty_direct")

        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 3)
        XCTAssertEqual(resume.params?.objectValue?["threadId"]?.stringValue, "thr_empty_direct")
        // 真实 app-server：刚 thread/start、还没跑过 turn 的空线程没有 rollout 文件，thread/resume 回
        // -32600 "no rollout found"。监听不能因此报错重连，必须吞掉并照常进入 connected。
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"error":{"code":-32600,"message":"no rollout found for thread id thr_empty_direct"}}"#)

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))
        XCTAssertFalse(statuses.contains { if case .failed = $0 { return true } else { return false } },
                       "空会话 resume 命中 no rollout found 不应让 WebSocket 进入 failed/重连")

        XCTAssertTrue(socket.sendTurn(CodexAppServerTurnPayload(prompt: "第一条消息"), clientMessageID: "client_empty_first"))
        let turnStart = try await waitForFakeAppServerRequest(transport, method: "turn/start", after: 4)
        XCTAssertEqual(turnStart.params?.objectValue?["threadId"]?.stringValue, "thr_empty_direct")
        XCTAssertEqual(turnStart.params?.objectValue?["clientUserMessageId"]?.stringValue, "client_empty_first")
        XCTAssertEqual(turnStart.params?.objectValue?["collaborationMode"]?.objectValue?["mode"]?.stringValue, "default")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: turnStart.id)),"result":{"turn":{"id":"turn_empty_first","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490603,"completedAt":null,"durationMs":null}}}"#)

        socket.disconnect()
    }

    // 回归：Claude 通道的 thread/start / thread/resume 必须先按 runtime 策略把 .default 草稿的
    // dangerFullAccess 降级为 workspace-write。旧行为原样携带 danger-full-access，gateway 以
    // -32080 拒绝 resume，事件订阅进入确定性失败的重连死循环，Claude 会话永远打不开。
    func testClaudeRuntimeThreadStartAndResumeDowngradeSandboxToWorkspaceWrite() async throws {
        let project = AgentProject(id: "proj_claude_sandbox", name: "Claude Sandbox", path: "/tmp/claude-sandbox")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "claude",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project, channels: [makeClaudeChannelMetadata()]) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "",
                input: [],
                resumeID: "",
                clientMessageID: nil
            ))
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-claude-bridge","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        XCTAssertEqual(
            threadStart.params?.objectValue?["sandbox"]?.stringValue,
            "workspace-write",
            "Claude 通道 thread/start 不应携带 danger-full-access"
        )
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_claude_sandbox","sessionId":"thr_claude_sandbox","preview":"","ephemeral":false,"modelProvider":"anthropic","createdAt":1780490700,"updatedAt":1780490701,"status":{"type":"idle"},"path":null,"cwd":"/tmp/claude-sandbox","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Claude 会话","turns":[]}}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.id, "thr_claude_sandbox")

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        socket.onStatus = { statuses.append($0) }
        socket.connect(sessionID: "thr_claude_sandbox")

        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 3)
        XCTAssertEqual(resume.params?.objectValue?["threadId"]?.stringValue, "thr_claude_sandbox")
        XCTAssertEqual(
            resume.params?.objectValue?["sandbox"]?.stringValue,
            "workspace-write",
            "Claude 通道 thread/resume 不应携带 danger-full-access（gateway 会 -32080 拒绝并造成重连死循环）"
        )
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"result":{"thread":{"id":"thr_claude_sandbox","sessionId":"thr_claude_sandbox","preview":"","ephemeral":false,"modelProvider":"anthropic","createdAt":1780490700,"updatedAt":1780490702,"status":{"type":"idle"},"path":null,"cwd":"/tmp/claude-sandbox","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Claude 会话","turns":[]}}}"#)

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))
        XCTAssertFalse(
            statuses.contains { if case .failed = $0 { return true } else { return false } },
            "Claude 会话 resume 不应进入 failed/重连"
        )
        socket.disconnect()
    }

    // performStartTurn 路径：thread/list 里认识但本连接尚未 resume 过的新线程，首次 startTurn 会先补
    // thread/resume。真实 app-server 对没跑过 turn 的线程回 -32600 no rollout found；修复后这一步被良性
    // 吞掉，turn/start 仍照常发出并落盘 rollout，而不是把首条消息直接打回失败。
    func testDirectStartTurnToleratesNoRolloutFoundResumeBeforeFirstTurn() async throws {
        let project = AgentProject(id: "proj_start_no_rollout", name: "Start No Rollout", path: "/tmp/start-no-rollout")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        // thread/list 让 runtime 认识这个还没跑过 turn 的线程（contextsBySessionID 填充），但本连接尚未
        // thread/resume 过它，于是首次 startTurn 会先补 resume。
        let listTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: nil)
        }
        let transport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let threadList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: threadList.id, result: #"{"data":[{"id":"thr_start_no_rollout","sessionId":"thr_start_no_rollout","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":1780490700,"updatedAt":1780490701,"status":{"type":"idle"},"path":null,"cwd":"/tmp/start-no-rollout","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"空会话","turns":[]}],"nextCursor":null}"#)
        _ = try await listTask.value

        let startTask = Task {
            try await runtime.startTurn(
                sessionID: "thr_start_no_rollout",
                payload: CodexAppServerTurnPayload(prompt: "第一条消息"),
                clientMessageID: "client_start_no_rollout"
            )
        }

        let beforeResumeMessages = await transport.sentMessages()
        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: beforeResumeMessages.count)
        XCTAssertEqual(resume.params?.objectValue?["threadId"]?.stringValue, "thr_start_no_rollout")
        // 真实 app-server 对没跑过 turn 的新线程回 -32600 no rollout found；修复后这一步被良性吞掉，不阻断
        // 后续 turn/start，而不是把首条消息直接打回失败。
        transportErrorResponse(transport, id: resume.id, code: -32600, message: "no rollout found for thread id thr_start_no_rollout")

        let beforeTurnMessages = await transport.sentMessages()
        let turnStart = try await waitForFakeAppServerRequest(transport, method: "turn/start", after: beforeTurnMessages.count)
        XCTAssertEqual(turnStart.params?.objectValue?["threadId"]?.stringValue, "thr_start_no_rollout")
        XCTAssertEqual(turnStart.params?.objectValue?["clientUserMessageId"]?.stringValue, "client_start_no_rollout")
        transportResponse(transport, id: turnStart.id, result: #"{"turn":{"id":"turn_start_no_rollout","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490702,"completedAt":null,"durationMs":null}}"#)

        let turnID = try await startTask.value
        XCTAssertEqual(turnID, "turn_start_no_rollout")
        XCTAssertNil(pool.transport(at: 1), "no rollout found 被良性吞掉，不应触发重连建立新 transport")
    }

    // 窄化保护：只有 no rollout found 才良性放行；其它 resume 失败（这里用 -32603 internal error）仍必须
    // 冒泡成 WebSocket failed，避免 isNoRolloutFoundError 把所有 resume 错误一锅端、掩盖真实故障。
    func testEmptyNewDirectSessionSurfacesNonRolloutResumeError() async throws {
        let project = AgentProject(id: "proj_resume_fail", name: "Resume Fail", path: "/tmp/resume-fail")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "",
                input: [],
                resumeID: "",
                clientMessageID: nil
            ))
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_resume_fail","sessionId":"thr_resume_fail","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":1780490800,"updatedAt":1780490801,"status":{"type":"idle"},"path":null,"cwd":"/tmp/resume-fail","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"空会话","turns":[]}}}"#)
        _ = try await createTask.value

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        socket.onStatus = { statuses.append($0) }
        socket.connect(sessionID: "thr_resume_fail")

        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 3)
        XCTAssertEqual(resume.params?.objectValue?["threadId"]?.stringValue, "thr_resume_fail")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"error":{"code":-32603,"message":"internal error"}}"#)

        func containsFailed(_ items: [WebSocketStatus]) -> Bool {
            items.contains { if case .failed = $0 { return true } else { return false } }
        }
        for _ in 0..<200 where !containsFailed(statuses) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(containsFailed(statuses), "非 no rollout found 的 resume 错误必须冒泡为 failed")
        XCTAssertFalse(statuses.contains(.connected), "resume 真失败时不应进入 connected")

        socket.disconnect()
    }

    func testDirectRuntimeAutoSkipsUserInputWhenPlanGuidanceDisabled() async throws {
        let project = AgentProject(id: "proj_plan_skip", name: "Plan Skip", path: "/tmp/plan-skip")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)
        var options = CodexAppServerTurnOptions.default
        options.model = "gpt-5-codex"
        options.collaborationMode = .plan
        options.planGuidanceEnabled = false

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "先规划",
                turnOptions: options,
                resumeID: "",
                clientMessageID: "client_plan_skip"
            ))
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        assertInitializeEnablesExperimentalAPI(initialize)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_plan_skip","sessionId":"thr_plan_skip","preview":"先规划","ephemeral":false,"modelProvider":"openai","createdAt":1780490100,"updatedAt":1780490101,"status":{"type":"idle"},"path":null,"cwd":"/tmp/plan-skip","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"计划跳过","turns":[]}}}"#)

        let turnMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let turnStart = try decodeAppServerRequest(turnMessages[3])
        XCTAssertEqual(turnStart.method, "turn/start")
        let turnParams = try XCTUnwrap(turnStart.params?.objectValue)
        XCTAssertEqual(turnParams["collaborationMode"]?.objectValue?["mode"]?.stringValue, "plan")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: turnStart.id)),"result":{"turn":{"id":"turn_plan_skip","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490102,"completedAt":null,"durationMs":null}}}"#)
        _ = try await createTask.value

        transport.enqueue(#"{"id":501,"method":"item/tool/requestUserInput","params":{"threadId":"thr_plan_skip","turnId":"turn_plan_skip","itemId":"input_skip","questions":[{"id":"scope","header":"范围","question":"要补充吗？","isOther":true,"isSecret":false,"options":[{"label":"后端","description":"先做 API"}]}]}}"#)
        let response = try await waitForFakeAppServerResponse(transport, id: .int(501))
        XCTAssertEqual(response.result?["answers"]?.objectValue?.isEmpty, true)
    }

    func testDirectSocketEmitsSendAcceptedOnlyAfterTurnStartSucceeds() async throws {
        let project = AgentProject(id: "proj_direct_accept", name: "Direct Accept", path: "/tmp/direct-accept")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "准备直连 socket",
                resumeID: "",
                clientMessageID: "client_direct_accept_initial"
            ))
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_direct_accept","sessionId":"thr_direct_accept","preview":"准备直连 socket","ephemeral":false,"modelProvider":"openai","createdAt":1780490500,"updatedAt":1780490501,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct-accept","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Direct accept","turns":[]}}}"#)

        let initialTurnMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let initialTurnStart = try decodeAppServerRequest(initialTurnMessages[3])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialTurnStart.id)),"result":{"turn":{"id":"turn_direct_accept_initial","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490502,"completedAt":null,"durationMs":null}}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.id, "thr_direct_accept")

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var acceptedIDs: [ClientMessageID?] = []
        var failures: [(ClientMessageID?, String)] = []
        socket.onStatus = { statuses.append($0) }
        socket.onSendAccepted = { acceptedIDs.append($0) }
        socket.onSendFailure = { failures.append(($0, $1)) }
        socket.connect(sessionID: "thr_direct_accept")

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        XCTAssertTrue(socket.sendTurn(CodexAppServerTurnPayload(prompt: "成功 turn"), clientMessageID: "client_direct_accept_success"))
        let successTurnStart = try await waitForFakeAppServerRequest(transport, method: "turn/start", after: 4)
        XCTAssertEqual(successTurnStart.method, "turn/start")
        XCTAssertEqual(successTurnStart.params?.objectValue?["clientUserMessageId"]?.stringValue, "client_direct_accept_success")
        XCTAssertTrue(acceptedIDs.isEmpty)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: successTurnStart.id)),"result":{"turn":{"id":"turn_direct_accept_success","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490503,"completedAt":null,"durationMs":null}}}"#)

        for _ in 0..<200 where !acceptedIDs.contains("client_direct_accept_success") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(acceptedIDs.contains("client_direct_accept_success"))
        XCTAssertTrue(failures.isEmpty)

        XCTAssertTrue(socket.sendTurn(CodexAppServerTurnPayload(prompt: "失败 turn"), clientMessageID: "client_direct_accept_fail"))
        let sentAfterSuccess = await transport.sentMessages()
        let failureTurnStart = try await waitForFakeAppServerRequest(
            transport,
            method: "turn/start",
            after: sentAfterSuccess.count
        )
        XCTAssertEqual(failureTurnStart.method, "turn/start")
        XCTAssertEqual(failureTurnStart.params?.objectValue?["clientUserMessageId"]?.stringValue, "client_direct_accept_fail")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: failureTurnStart.id)),"error":{"code":-32000,"message":"turn failed"}}"#)

        for _ in 0..<200 where failures.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(failures.first?.0, "client_direct_accept_fail")
        XCTAssertFalse(acceptedIDs.contains("client_direct_accept_fail"))

        socket.disconnect()
    }

    func testCodexAppServerSessionRuntimeForwardsRichCreatePayload() async throws {
        let project = AgentProject(id: "proj_direct_rich", name: "Direct Rich", path: "/tmp/direct-rich")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)
        var options = CodexAppServerTurnOptions.default
        options.model = "gpt-5.1-codex"
        options.modelProvider = "openai"
        options.serviceTier = "priority"
        options.reasoningEffort = .high
        options.approvalPolicy = .onFailure
        options.sandboxMode = .readOnly
        options.baseInstructions = "base"
        options.developerInstructions = "dev"
        let payload = CodexAppServerTurnPayload(input: [
            .text("分析截图"),
            .image(url: "data:image/png;base64,AA==", detail: .high),
            .skill(name: "review", path: project.path + "/.codex/skills/review/SKILL.md")
        ], options: options)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: payload.previewText,
                input: payload.input,
                turnOptions: payload.options,
                resumeID: "",
                clientMessageID: "client_direct_rich"
            ))
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        let threadParams = try XCTUnwrap(threadStart.params?.objectValue)
        XCTAssertNil(threadParams["model"]?.stringValue)
        XCTAssertNil(threadParams["modelProvider"])
        XCTAssertEqual(threadParams["serviceTier"]?.stringValue, "priority")
        XCTAssertEqual(threadParams["approvalPolicy"]?.stringValue, "on-failure")
        XCTAssertEqual(threadParams["sandbox"]?.stringValue, "read-only")
        XCTAssertEqual(threadParams["baseInstructions"]?.stringValue, "base")
        XCTAssertEqual(threadParams["developerInstructions"]?.stringValue, "dev")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_direct_rich","sessionId":"thr_direct_rich","preview":"分析截图","ephemeral":false,"modelProvider":"openai","createdAt":1780490400,"updatedAt":1780490401,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct-rich","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Rich direct","turns":[]}}}"#)

        let turnMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let turnStart = try decodeAppServerRequest(turnMessages[3])
        XCTAssertEqual(turnStart.method, "turn/start")
        let turnParams = try XCTUnwrap(turnStart.params?.objectValue)
        XCTAssertEqual(turnParams["threadId"]?.stringValue, "thr_direct_rich")
        XCTAssertEqual(turnParams["clientUserMessageId"]?.stringValue, "client_direct_rich")
        XCTAssertEqual(turnParams["model"]?.stringValue, "gpt-5.1-codex")
        XCTAssertEqual(turnParams["serviceTier"]?.stringValue, "priority")
        XCTAssertEqual(turnParams["effort"]?.stringValue, "high")
        XCTAssertEqual(turnParams["approvalPolicy"]?.stringValue, "on-failure")
        XCTAssertNil(turnParams["modelProvider"])
        XCTAssertNil(turnParams["baseInstructions"])
        let input = try XCTUnwrap(turnParams["input"]?.arrayValue)
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input[0].objectValue?["text"]?.stringValue, "分析截图")
        XCTAssertEqual(input[1].objectValue?["detail"]?.stringValue, "high")
        XCTAssertEqual(input[2].objectValue?["path"]?.stringValue, project.path + "/.codex/skills/review/SKILL.md")
        let sandbox = try XCTUnwrap(turnParams["sandboxPolicy"]?.objectValue)
        XCTAssertEqual(sandbox["type"]?.stringValue, "readOnly")
        XCTAssertEqual(sandbox["networkAccess"]?.boolValue, false)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: turnStart.id)),"result":{"turn":{"id":"turn_direct_rich","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490402,"completedAt":null,"durationMs":null}}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.id, "thr_direct_rich")
        XCTAssertEqual(created.session.activeTurnID, "turn_direct_rich")
    }

    func testClaudeRuntimeCreateSessionResponseUsesClaudeGatewayURL() async throws {
        let project = AgentProject(id: "proj_claude_url", name: "Claude URL", path: "/tmp/claude-url")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "claude",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(project: project, channels: [
                    CodexAppServerChannelMetadata(
                        id: "claude",
                        runtimeID: "claude",
                        title: "Claude Code",
                        provider: "anthropic",
                        type: "claude_code_bridge",
                        protocolName: "app_server_jsonrpc_stdio_v1",
                        gatewayWSURL: "ws://127.0.0.1:7777/api/app-server/ws?runtime=claude",
                        gatewayAvailable: true,
                        managed: false,
                        experimental: true,
                        lifecycle: "per_connection",
                        bridge: nil,
                        methods: ["initialize", "initialized", "thread/start"],
                        capabilities: ["history": true]
                    )
                ])
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "",
                input: [],
                turnOptions: .default,
                resumeID: "",
                clientMessageID: nil
            ))
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-claude","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_claude_url","sessionId":"thr_claude_url","preview":"","ephemeral":false,"createdAt":1780490400,"updatedAt":1780490401,"status":{"type":"idle"},"path":null,"cwd":"/tmp/claude-url","cliVersion":"0.0.0","source":"claude","threadSource":"user","name":"Claude URL","turns":[]}}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.runtimeProvider, "claude")
        XCTAssertTrue(created.wsURL.contains("runtime=claude"), "Claude create wsURL 应包含 runtime=claude，got \(created.wsURL)")
    }

    func testDirectRuntimeClearsApprovalWhenResolvedNotificationOnlyHasRequestID() async throws {
        let project = AgentProject(id: "proj_resolved", name: "Resolved", path: "/tmp/resolved")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let sessionTask = Task {
            try await client.session(id: "thr_resolved")
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_resolved","sessionId":"thr_resolved","preview":"等待审批清理","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/resolved","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"等待审批清理","turns":[]}}}"#)
        _ = try await sessionTask.value

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }
        socket.connect(sessionID: "thr_resolved")

        let resumeMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let resume = try decodeAppServerRequest(resumeMessages[3])
        XCTAssertEqual(resume.method, "thread/resume")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"result":{"thread":{"id":"thr_resolved","sessionId":"thr_resolved","preview":"等待审批清理","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/resolved","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"等待审批清理","turns":[]}}}"#)

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        // 真实审批一定发生在进行中的 turn 内：先让 thread 进入活跃 turn，审批才会被当作有效请求展示，
        // 而不是被当成 resume 重放的过期僵尸丢弃。
        transport.enqueue(#"{"method":"turn/started","params":{"threadId":"thr_resolved","turn":{"id":"turn_resolved"}}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .turnStarted(let metadata) = $0 {
                return metadata.sessionID == "thr_resolved"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        transport.enqueue(#"{"id":101,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_resolved","turnId":"turn_resolved","itemId":"cmd_resolved","command":"xcrun devicectl list devices"}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .approvalRequest(let approval, _) = $0 {
                return approval.id == "cmd_resolved"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .approvalRequest(let approval, _) = $0 {
                return approval.id == "cmd_resolved"
            }
            return false
        })

        XCTAssertTrue(socket.sendApprovalDecision(approvalID: "cmd_resolved", decision: "accept", message: nil))
        let approvalResponse = try await waitForFakeAppServerResponse(transport, id: .int(101))
        XCTAssertEqual(approvalResponse.result?["decision"]?.stringValue, "accept")

        transport.enqueue(#"{"method":"serverRequest/resolved","params":{"requestId":101}}"#)
        for _ in 0..<200 where !events.contains(where: {
            if case .approvalResolved(let metadata) = $0 {
                return metadata.sessionID == "thr_resolved"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .approvalResolved(let metadata) = $0 {
                return metadata.sessionID == "thr_resolved"
            }
            return false
        })

        socket.disconnect()
    }

    func testDirectRuntimeServesEarlierHistoryFromCacheWithoutRefetch() async throws {
        let project = AgentProject(id: "proj_hist", name: "Hist", path: "/tmp/hist")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        // 首屏 before=nil：触发一次整段 thread/read。
        let firstPageTask = Task {
            try await client.messagesPage(sessionID: "thr_hist", before: nil, limit: 2)
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_hist","sessionId":"thr_hist","preview":"hist","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/hist","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"hist","turns":[{"id":"turn_h","startedAt":1780490000,"items":[{"type":"userMessage","id":"item_0","content":[{"type":"text","text":"m0"}]},{"type":"userMessage","id":"item_1","content":[{"type":"text","text":"m1"}]},{"type":"userMessage","id":"item_2","content":[{"type":"text","text":"m2"}]}]}]}}}"#)

        let firstPage = try await firstPageTask.value
        XCTAssertEqual(firstPage.messages.map(\.content), ["m1", "m2"])
        XCTAssertTrue(firstPage.hasMoreBefore)
        let cursor = try XCTUnwrap(firstPage.previousCursor)

        // 翻看更早 before=cursor：必须命中缓存，能取回最早的 m0，并且不再发第二次 thread/read。
        let earlier = try await client.messagesPage(sessionID: "thr_hist", before: cursor, limit: 2)
        XCTAssertEqual(earlier.messages.map(\.content), ["m0"])
        XCTAssertFalse(earlier.hasMoreBefore)

        let sent = await transport.sentMessages()
        let threadReadCount = sent.compactMap { try? decodeAppServerRequest($0) }.filter { $0.method == "thread/read" }.count
        XCTAssertEqual(threadReadCount, 1, "翻看更早历史应命中缓存，不应再次拉取整段 thread/read")
    }

    func testDirectRuntimePreservesHistoryImagePayloadAsLazyMedia() async throws {
        let project = AgentProject(id: "proj_hist_image", name: "Hist Image", path: "/tmp/hist-image")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(sessionID: "thr_hist_image", before: nil, limit: 10)
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_hist_image","sessionId":"thr_hist_image","preview":"hist image","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/hist-image","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"hist image","turns":[{"id":"turn_img","startedAt":1780490000,"items":[{"type":"userMessage","id":"item_img","content":[{"type":"text","text":"看这张截图"},{"type":"image","url":"agentd-history-media://media_abc","detail":"high","redacted":true,"contentType":"image/png","byteCount":2048}]}]}]}}}"#)

        let page = try await pageTask.value
        let message = try XCTUnwrap(page.messages.first)
        XCTAssertEqual(message.content, "看这张截图")
        XCTAssertEqual(message.turnPayload?.textPrompt, "看这张截图")
        XCTAssertTrue(payloadContainsImageURL(message.turnPayload, url: "agentd-history-media://media_abc"))
    }

    func testDirectRuntimeParsesHistoryTurnDatesFromISOAndMilliseconds() async throws {
        let project = AgentProject(id: "proj_hist_dates", name: "Hist Dates", path: "/tmp/hist-dates")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(sessionID: "thr_hist_dates", before: nil, limit: 10)
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let read = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_hist_dates","sessionId":"thr_hist_dates","preview":"hist dates","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/hist-dates","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"hist dates","turns":[{"id":"turn_iso","startedAt":"2026-07-01T18:16:00.000Z","completedAt":"2026-07-01T18:16:01.154Z","items":[{"type":"userMessage","id":"user_iso","content":[{"type":"text","text":"iso user"}]},{"type":"agentMessage","id":"assistant_iso","text":"iso assistant","phase":"final_answer"}]},{"id":"turn_ms","startedAt":1782929761154,"completedAt":"1782929762123","items":[{"type":"userMessage","id":"user_ms","content":[{"type":"text","text":"ms user"}]},{"type":"agentMessage","id":"assistant_ms","text":"ms assistant","phase":"final_answer"}]},{"id":"turn_snake","started_at":"2026-07-01T19:00:00.000Z","completed_at":"2026-07-01T19:00:02.000Z","items":[{"type":"userMessage","id":"user_snake","content":[{"type":"text","text":"snake user"}]},{"type":"agentMessage","id":"assistant_snake","text":"snake assistant","phase":"final_answer"}]},{"id":"turn_item_only","items":[{"type":"userMessage","id":"user_item","created_at":1782932403,"content":[{"type":"text","text":"item user"}]},{"type":"agentMessage","id":"assistant_item","updated_at":"2026-07-01T19:00:04.500Z","text":"item assistant","phase":"final_answer"}]}]}}}"#)

        let page = try await pageTask.value
        let isoUser = try XCTUnwrap(page.messages.first { $0.content == "iso user" })
        let isoAssistant = try XCTUnwrap(page.messages.first { $0.content == "iso assistant" })
        let msUser = try XCTUnwrap(page.messages.first { $0.content == "ms user" })
        let msAssistant = try XCTUnwrap(page.messages.first { $0.content == "ms assistant" })
        let snakeUser = try XCTUnwrap(page.messages.first { $0.content == "snake user" })
        let snakeAssistant = try XCTUnwrap(page.messages.first { $0.content == "snake assistant" })
        let itemUser = try XCTUnwrap(page.messages.first { $0.content == "item user" })
        let itemAssistant = try XCTUnwrap(page.messages.first { $0.content == "item assistant" })

        XCTAssertEqual(try XCTUnwrap(isoUser.createdAt).timeIntervalSince1970, 1_782_929_760, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(isoAssistant.createdAt).timeIntervalSince1970, 1_782_929_761.154, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(isoAssistant.updatedAt).timeIntervalSince1970, 1_782_929_761.154, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(msUser.createdAt).timeIntervalSince1970, 1_782_929_761.154, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(msAssistant.createdAt).timeIntervalSince1970, 1_782_929_762.123, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(msAssistant.updatedAt).timeIntervalSince1970, 1_782_929_762.123, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snakeUser.createdAt).timeIntervalSince1970, 1_782_932_400, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snakeAssistant.createdAt).timeIntervalSince1970, 1_782_932_402, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(itemUser.createdAt).timeIntervalSince1970, 1_782_932_403, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(itemAssistant.createdAt).timeIntervalSince1970, 1_782_932_404.5, accuracy: 0.001)
        XCTAssertTrue(isoUser.isTimestampFallback)
        XCTAssertFalse(isoAssistant.isTimestampFallback)
        XCTAssertTrue(msUser.isTimestampFallback)
        XCTAssertFalse(msAssistant.isTimestampFallback)
        XCTAssertTrue(snakeUser.isTimestampFallback)
        XCTAssertFalse(snakeAssistant.isTimestampFallback)
        XCTAssertFalse(itemUser.isTimestampFallback)
        XCTAssertFalse(itemAssistant.isTimestampFallback)
    }

    func testDirectRuntimeStampsActiveSnapshotItemsWithReadTime() async throws {
        let project = AgentProject(id: "proj_hist_active_time", name: "Hist Active", path: "/tmp/hist-active")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(sessionID: "thr_hist_active_time", before: nil, limit: 10)
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let read = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        let lowerBound = Date()
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_hist_active_time","sessionId":"thr_hist_active_time","preview":"active time","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"active"},"path":null,"cwd":"/tmp/hist-active","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"active time","turns":[{"id":"turn_live_time","startedAt":1780490000,"status":"inProgress","items":[{"type":"userMessage","id":"user_live","content":[{"type":"text","text":"继续观察"}]},{"type":"commandExecution","id":"cmd_live","command":"go test ./...","status":"running"},{"type":"commandExecution","id":"cmd_failed","command":"xcodebuild test","status":"failed"},{"type":"agentMessage","id":"assistant_live","text":"还在输出日志","phase":"final_answer"}]}]}}}"#)

        let page = try await pageTask.value
        let upperBound = Date()
        let user = try XCTUnwrap(page.messages.first { $0.content == "继续观察" })
        let command = try XCTUnwrap(page.messages.first { $0.content.contains("go test ./...") })
        let failedCommand = try XCTUnwrap(page.messages.first { $0.content.contains("xcodebuild test") })
        let assistant = try XCTUnwrap(page.messages.first { $0.content == "还在输出日志" })

        XCTAssertNil(user.updatedAt)
        XCTAssertNil(failedCommand.updatedAt)
        for message in [command, assistant] {
            let updatedAt = try XCTUnwrap(message.updatedAt)
            XCTAssertGreaterThan(updatedAt, try XCTUnwrap(message.createdAt))
            XCTAssertGreaterThanOrEqual(updatedAt.timeIntervalSince1970, lowerBound.addingTimeInterval(-1).timeIntervalSince1970)
            XCTAssertLessThanOrEqual(updatedAt.timeIntervalSince1970, upperBound.addingTimeInterval(1).timeIntervalSince1970)
        }
    }

    func testDirectRuntimeMarksMissingHistoryTimestampsAsFallback() async throws {
        let project = AgentProject(id: "proj_hist_fallback", name: "Hist Fallback", path: "/tmp/hist-fallback")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(sessionID: "thr_hist_fallback", before: nil, limit: 10)
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let read = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_hist_fallback","sessionId":"thr_hist_fallback","preview":"hist fallback","ephemeral":false,"modelProvider":"openai","createdAt":1780490400,"updatedAt":1780490500,"status":{"type":"idle"},"path":null,"cwd":"/tmp/hist-fallback","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"hist fallback","turns":[{"id":"turn_missing","items":[{"type":"userMessage","id":"user_missing","content":[{"type":"text","text":"missing user"}]},{"type":"agentMessage","id":"assistant_missing","text":"missing assistant","phase":"final_answer"}]}]}}}"#)

        let page = try await pageTask.value
        XCTAssertEqual(page.messages.map(\.content), ["missing user", "missing assistant"])
        XCTAssertTrue(page.messages.allSatisfy(\.isTimestampFallback))
        XCTAssertEqual(try XCTUnwrap(page.messages.first?.createdAt).timeIntervalSince1970, 1_780_490_500, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(page.messages.last?.createdAt).timeIntervalSince1970, 1_780_490_500, accuracy: 0.001)
    }

    func testDirectRuntimeMarksMiddleUserMessageAsInjectedServerFact() async throws {
        let project = AgentProject(id: "proj_hist_injected", name: "Hist Injected", path: "/tmp/hist-injected")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(sessionID: "thr_hist_injected", before: nil, limit: 10)
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let read = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_hist_injected","sessionId":"thr_hist_injected","preview":"injected","ephemeral":false,"modelProvider":"openai","createdAt":1780490600,"updatedAt":1780490630,"status":{"type":"idle"},"path":null,"cwd":"/tmp/hist-injected","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"injected","turns":[{"id":"turn_injected","startedAt":1780490600,"completedAt":1780490630,"items":[{"type":"userMessage","id":"user_initial","clientId":"client_initial","content":[{"type":"text","text":"先排查"}]},{"type":"agentMessage","id":"commentary_injected","text":"我先看当前状态。","phase":"commentary"},{"type":"userMessage","id":"user_mid","clientId":"client_mid","content":[{"type":"text","text":"要求后续变更"}]},{"type":"agentMessage","id":"assistant_injected","text":"已按后续要求完成。","phase":"final_answer"}]}]}}}"#)

        let page = try await pageTask.value
        XCTAssertEqual(page.messages.map(\.content), ["先排查", "我先看当前状态。", "要求后续变更", "已按后续要求完成。"])
        let firstUser = try XCTUnwrap(page.messages.first { $0.content == "先排查" })
        let middleUser = try XCTUnwrap(page.messages.first { $0.content == "要求后续变更" })

        XCTAssertNil(firstUser.userDelivery)
        XCTAssertEqual(middleUser.userDelivery, .injected)
        XCTAssertLessThan(try XCTUnwrap(firstUser.timelineOrdinal), try XCTUnwrap(middleUser.timelineOrdinal))
    }

    func testDirectRuntimeUsesPagedThreadTurnsListWhenGatewayAllowsIt() async throws {
        let project = AgentProject(id: "proj_turn_pages", name: "Turn Pages", path: "/tmp/turn-pages")
        let transport = FakeCodexAppServerTransport()
        let allowedMethods = [
            "initialize",
            "initialized",
            "thread/list",
            "thread/start",
            "thread/read",
            "thread/turns/list",
            "turn/start",
            "turn/interrupt"
        ]
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project, allowedMethods: allowedMethods) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let firstPageTask = Task {
            try await client.messagesPage(sessionID: "thr_turn_pages", before: nil, limit: 120)
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let metadataRead = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        XCTAssertEqual(metadataRead.params?.objectValue?["includeTurns"]?.boolValue, false)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: metadataRead.id)),"result":{"thread":{"id":"thr_turn_pages","sessionId":"thr_turn_pages","preview":"turn pages","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"notLoaded"},"path":null,"cwd":"/tmp/turn-pages","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"turn pages","turns":[]}}}"#)

        let firstTurnsRequest = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list")
        XCTAssertEqual(firstTurnsRequest.params?.objectValue?["limit"]?.intValue, 50)
        XCTAssertEqual(firstTurnsRequest.params?.objectValue?["sortDirection"]?.stringValue, "desc")
        XCTAssertEqual(firstTurnsRequest.params?.objectValue?["itemsView"]?.stringValue, "full")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: firstTurnsRequest.id)),"result":{"data":[{"id":"turn_new","items":[{"type":"userMessage","id":"item_3","created_at":1780490302,"content":[{"type":"text","text":"m3"}]},{"type":"agentMessage","id":"item_4","updated_at":1780490303,"text":"m4","phase":"final_answer"}]},{"id":"turn_old","started_at":1780490300,"completed_at":1780490301,"items":[{"type":"userMessage","id":"item_1","content":[{"type":"text","text":"m1"}]},{"type":"agentMessage","id":"item_2","text":"m2","phase":"final_answer"}]}],"nextCursor":"older-cursor","backwardsCursor":"newer-cursor"}}"#)

        let firstPage = try await firstPageTask.value
        XCTAssertEqual(firstPage.messages.map(\.content), ["m1", "m2", "m3", "m4"])
        XCTAssertEqual(try XCTUnwrap(firstPage.messages.first { $0.content == "m4" }?.createdAt).timeIntervalSince1970, 1_780_490_303, accuracy: 0.001)
        XCTAssertTrue(try XCTUnwrap(firstPage.messages.first { $0.content == "m1" }).isTimestampFallback)
        XCTAssertFalse(try XCTUnwrap(firstPage.messages.first { $0.content == "m2" }).isTimestampFallback)
        XCTAssertFalse(try XCTUnwrap(firstPage.messages.first { $0.content == "m3" }).isTimestampFallback)
        XCTAssertFalse(try XCTUnwrap(firstPage.messages.first { $0.content == "m4" }).isTimestampFallback)
        XCTAssertTrue(firstPage.hasMoreBefore)
        let cursor = try XCTUnwrap(firstPage.previousCursor)

        let sentBeforeEarlierPage = await transport.sentMessages().count
        let earlierPageTask = Task {
            try await client.messagesPage(sessionID: "thr_turn_pages", before: cursor, limit: 120)
        }
        let earlierTurnsRequest = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/turns/list",
            after: sentBeforeEarlierPage
        )
        XCTAssertEqual(earlierTurnsRequest.params?.objectValue?["cursor"]?.stringValue, "older-cursor")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: earlierTurnsRequest.id)),"result":{"data":[{"id":"turn_earliest","startedAt":1780490200,"items":[{"type":"userMessage","id":"item_0","content":[{"type":"text","text":"m0"}]}]}],"nextCursor":null,"backwardsCursor":"mid-cursor"}}"#)

        let earlierPage = try await earlierPageTask.value
        XCTAssertEqual(earlierPage.messages.map(\.content), ["m0"])
        XCTAssertFalse(earlierPage.hasMoreBefore)

        let sent = await transport.sentMessages()
        let requests = sent.compactMap { try? decodeAppServerRequest($0) }
        XCTAssertEqual(requests.filter { $0.method == "thread/turns/list" }.count, 2)
        XCTAssertFalse(requests.contains { request in
            request.method == "thread/read" && request.params?.objectValue?["includeTurns"]?.boolValue == true
        })
    }

    func testDirectRuntimeEconomyHistoryUsesSummaryTurnPagesAndNotice() async throws {
        let project = AgentProject(id: "proj_turn_pages_economy", name: "Turn Pages Economy", path: "/tmp/turn-pages-economy")
        let transport = FakeCodexAppServerTransport()
        let allowedMethods = [
            "initialize",
            "initialized",
            "thread/list",
            "thread/start",
            "thread/read",
            "thread/turns/list",
            "turn/start",
            "turn/interrupt"
        ]
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project, allowedMethods: allowedMethods) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(
                sessionID: "thr_turn_pages_economy",
                before: nil,
                limit: 60,
                loadMode: .economy
            )
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let metadataRead = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        XCTAssertEqual(metadataRead.params?.objectValue?["includeTurns"]?.boolValue, false)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: metadataRead.id)),"result":{"thread":{"id":"thr_turn_pages_economy","sessionId":"thr_turn_pages_economy","preview":"economy","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"notLoaded"},"path":null,"cwd":"/tmp/turn-pages-economy","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"economy","turns":[]}}}"#)

        let turnsRequest = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list")
        XCTAssertEqual(turnsRequest.params?.objectValue?["limit"]?.intValue, 15)
        XCTAssertEqual(turnsRequest.params?.objectValue?["itemsView"]?.stringValue, "summary")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: turnsRequest.id)),"result":{"data":[{"id":"turn_summary","itemsView":"summary","items":[{"type":"userMessage","id":"item_1","created_at":1780490302,"content":[{"type":"text","text":"m1"}]},{"type":"agentMessage","id":"item_2","updated_at":1780490303,"text":"m2","phase":"final_answer"}]}],"nextCursor":"older-cursor"}}"#)

        let page = try await pageTask.value
        XCTAssertEqual(page.messages.map(\.content), ["m1", "m2"])
        XCTAssertEqual(page.loadMode, .economy)
        XCTAssertEqual(page.notice, "此会话包含较大的图片或工具输出，已使用省流模式加载。")
        XCTAssertTrue(page.hasMoreBefore)
    }

    func testDirectRuntimeThreadReadBackfillsHistoryContextFromTurns() async throws {
        let project = AgentProject(id: "proj_context", name: "Context", path: "/tmp/context")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let firstPageTask = Task {
            try await client.messagesPage(sessionID: "thr_context", before: nil, limit: 2)
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        XCTAssertEqual(read.params?.objectValue?["includeTurns"]?.boolValue, true)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_context","sessionId":"thr_context","preview":"context","ephemeral":false,"modelProvider":"openai","createdAt":1780490200,"updatedAt":1780490201,"status":{"type":"idle"},"path":null,"cwd":"/tmp/context","cliVersion":"0.0.0","source":{"custom":"vscode"},"threadSource":"user","forkedFromId":"thr_parent","name":"context","turns":[{"id":"turn_context","startedAt":1780490200,"completedAt":1780490201,"status":"completed","items":[{"type":"userMessage","id":"user_context","content":[{"type":"text","text":"检查右栏 context"}]},{"type":"commandExecution","id":"cmd_context","command":"go test ./...","cwd":"/tmp/context","status":"completed","commandActions":[]},{"type":"fileChange","id":"file_context","status":"modified","changes":[{"path":"Sources/App.swift","kind":"modified"}]},{"type":"mcpToolCall","id":"mcp_context","server":"figma","tool":"get_design","pluginId":"figma","status":"completed"},{"type":"dynamicToolCall","id":"dyn_context","namespace":"tool_search","tool":"tool_search_tool","pluginId":"browser","status":"completed"},{"type":"collabAgentToolCall","id":"sub_context","tool":"Zeno","agentNickname":"Zeno","agentRole":"review","childThreadId":"thr_child","status":"completed"},{"type":"webSearch","id":"web_context","query":"SwiftUI Inspector","status":"completed"},{"type":"agentMessage","id":"assistant_context","text":"已完成 context 检查","phase":"final_answer"}]}]}}}"#)

        let firstPage = try await firstPageTask.value
        let context = try XCTUnwrap(firstPage.context)
        XCTAssertEqual(context.sessionID, "thr_context")
        XCTAssertEqual(context.environment?.cwd, "/tmp/context")
        XCTAssertEqual(context.sources.map(\.id), ["session_source", "thread_source", "forked_from"])
        XCTAssertEqual(context.sources.first?.label, "vscode")
        XCTAssertTrue(context.tasks.contains { $0.id == "cmd_context" && $0.kind == "command" && $0.title == "go test ./..." })
        XCTAssertTrue(context.tasks.contains { $0.id == "file_context" && $0.kind == "file_change" })
        XCTAssertTrue(context.tasks.contains { $0.id == "mcp_context" && $0.kind == "mcp_tool" })
        XCTAssertTrue(context.tasks.contains { $0.id == "dyn_context" && $0.kind == "dynamic_tool" })
        XCTAssertTrue(context.tasks.contains { $0.id == "sub_context" && $0.kind == "subagent" })
        XCTAssertTrue(context.tasks.contains { $0.id == "web_context" && $0.kind == "web_search" })
        XCTAssertEqual(context.subagents.first?.id, "thr_child")
        XCTAssertEqual(context.subagents.first?.parentThreadID, "thr_context")
        XCTAssertEqual(context.subagents.first?.displayName, "Zeno")

        let cursor = try XCTUnwrap(firstPage.previousCursor)
        let earlier = try await client.messagesPage(sessionID: "thr_context", before: cursor, limit: 2)
        XCTAssertEqual(earlier.context?.subagents.first?.id, "thr_child")

        let sent = await transport.sentMessages()
        let threadReadCount = sent.compactMap { try? decodeAppServerRequest($0) }.filter { $0.method == "thread/read" }.count
        XCTAssertEqual(threadReadCount, 1, "翻看更早历史应复用 history/context 缓存")
    }

    func testDirectRuntimeMapsThreadReadProcessItemsForTimelineCollapse() async throws {
        let project = AgentProject(id: "proj_processed_history", name: "Processed", path: "/tmp/processed")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(sessionID: "thr_processed", before: nil, limit: nil)
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_processed","sessionId":"thr_processed","preview":"调用子 agent 讲个笑话","ephemeral":false,"modelProvider":"openai","createdAt":1780490100,"updatedAt":1780490134,"status":{"type":"idle"},"path":null,"cwd":"/tmp/processed","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"processed","turns":[{"id":"turn_processed","startedAt":1780490100,"completedAt":1780490134,"itemsView":"full","status":"completed","error":null,"items":[{"type":"userMessage","id":"user_processed","clientId":"client_processed","content":[{"type":"text","text":"调用子 agent 讲个笑话"}]},{"type":"agentMessage","id":"commentary_processed","text":"我先调用一个子 agent。","phase":"commentary","memoryCitation":null},{"type":"plan","id":"plan_processed","text":"让子 agent 生成一个短笑话。"},{"type":"reasoning","id":"reasoning_processed","summary":["确认请求要讲笑话"],"content":[]},{"type":"commandExecution","id":"cmd_processed","command":"echo joke","cwd":"/tmp/processed","processId":null,"source":"exec","status":"completed","commandActions":[],"aggregatedOutput":"ok","exitCode":0,"durationMs":1000},{"type":"agentMessage","id":"assistant_processed","text":"程序员相亲，对方问：你会浪漫吗？","phase":"final_answer","memoryCitation":null}]}]}}}"#)

        let page = try await pageTask.value
        XCTAssertEqual(page.messages.map(\.role), ["user", "system", "system", "system", "system", "assistant"])
        XCTAssertEqual(page.messages.map(\.kind), [.message, .reasoningSummary, .plan, .reasoningSummary, .commandSummary, .message])
        XCTAssertEqual(page.messages.last?.createdAt, Date(timeIntervalSince1970: 1780490134))
        let historyCommand = try XCTUnwrap(page.messages.first { $0.itemID == "cmd_processed" })
        XCTAssertEqual(historyCommand.activityPayload?.category, .runCommand)
        XCTAssertEqual(historyCommand.activityPayload?.displayTitle, "运行 echo joke")

        var projector = CodexAppServerEventProjector()
        let liveCommand = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_processed","turnId":"turn_processed","item":{"type":"commandExecution","id":"cmd_processed","command":"echo joke","cwd":"/tmp/processed","processId":null,"source":"exec","status":"completed","commandActions":[],"aggregatedOutput":"ok","exitCode":0,"durationMs":1000}}}"#)
        if case .processItemCompleted(let liveMessage, _, _) = try XCTUnwrap(projector.project(liveCommand)) {
            XCTAssertEqual(liveMessage.content, historyCommand.content)
            XCTAssertEqual(liveMessage.activityPayload, historyCommand.activityPayload)
        } else {
            XCTFail("Expected live command process item")
        }

        let conversationStore = ConversationStore()
        conversationStore.setHistory(page.messages, sessionID: "thr_processed")
        let items = ConversationTimelineItemBuilder.items(from: conversationStore.messages(for: "thr_processed"))

        XCTAssertEqual(items.count, 4)
        guard case .processed(let group) = items[1] else {
            return XCTFail("thread/read 过程 item 应折叠到最终 assistant 前")
        }
        XCTAssertEqual(group.messages.map(\.kind), [.reasoningSummary, .reasoningSummary, .commandSummary])
        guard case .message(let final) = items[2] else {
            return XCTFail("最终 assistant 应保持独立展开")
        }
        XCTAssertEqual(final.role, .assistant)
        XCTAssertEqual(final.content, "程序员相亲，对方问：你会浪漫吗？")
        guard case .message(let plan) = items[3] else {
            return XCTFail("plan 应固定在最终 assistant 后")
        }
        XCTAssertEqual(plan.kind, .plan)
        XCTAssertEqual(plan.content, "让子 agent 生成一个短笑话。")
    }

    func testDirectRuntimeDropsStaleReplayedApprovalForIdleThread() async throws {
        let project = AgentProject(id: "proj_stale", name: "Stale", path: "/tmp/stale")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let sessionTask = Task {
            try await client.session(id: "thr_stale")
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_stale","sessionId":"thr_stale","preview":"僵尸审批","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/stale","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"僵尸审批","turns":[]}}}"#)
        _ = try await sessionTask.value

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }
        socket.connect(sessionID: "thr_stale")

        let resumeMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let resume = try decodeAppServerRequest(resumeMessages[3])
        XCTAssertEqual(resume.method, "thread/resume")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"result":{"thread":{"id":"thr_stale","sessionId":"thr_stale","preview":"僵尸审批","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"idle"},"path":null,"cwd":"/tmp/stale","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"僵尸审批","turns":[]}}}"#)

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        // 模拟 app-server 在 resume 时重放一个早已被放弃的审批：thread 当前权威状态是 idle、没有活跃 turn。
        transport.enqueue(#"{"id":4242,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_stale","turnId":"turn_dead","itemId":"cmd_dead","command":"xcrun devicectl list devices"}}"#)

        // 运行时应当直接回 decline 把僵尸请求从 app-server 挂起表里释放，而不是把它当成有效审批弹给 UI。
        let release = try await waitForFakeAppServerResponse(transport, id: .int(4242))
        XCTAssertEqual(release.result?["decision"]?.stringValue, "decline")

        XCTAssertFalse(events.contains {
            if case .approvalRequest = $0 {
                return true
            }
            return false
        }, "过期重放的审批不应再作为有效审批卡展示")

        socket.disconnect()
    }

    func testDirectRuntimeDropsStaleReplayedApprovalForOldTurnWhileCurrentTurnIsActive() async throws {
        let project = AgentProject(id: "proj_stale_turn", name: "Stale Turn", path: "/tmp/stale-turn")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let sessionTask = Task {
            try await client.session(id: "thr_stale_turn")
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_stale_turn","sessionId":"thr_stale_turn","preview":"旧 turn 审批","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"active","activeFlags":["waitingOnApproval"]},"path":null,"cwd":"/tmp/stale-turn","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"旧 turn 审批","turns":[{"id":"turn_current","status":"inProgress","items":[]}]}}}"#)
        let sessionResponse = try await sessionTask.value
        let session = sessionResponse.session
        XCTAssertEqual(session.status, "waiting_for_approval")
        XCTAssertEqual(session.activeTurnID, "turn_current")

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }
        socket.connect(sessionID: "thr_stale_turn")

        let resumeMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let resume = try decodeAppServerRequest(resumeMessages[3])
        XCTAssertEqual(resume.method, "thread/resume")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"result":{"thread":{"id":"thr_stale_turn","sessionId":"thr_stale_turn","preview":"旧 turn 审批","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"active","activeFlags":["waitingOnApproval"]},"path":null,"cwd":"/tmp/stale-turn","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"旧 turn 审批","turns":[{"id":"turn_current","status":"inProgress","items":[]}]}}}"#)

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        // 真实现场：thread 当前有新的 active turn，但 app-server 还重放旧 turn 的未决审批。
        transport.enqueue(#"{"id":5151,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_stale_turn","turnId":"turn_old","itemId":"cmd_old","command":"/bin/zsh -lc 'xcrun devicectl list devices'"}}"#)

        let release = try await waitForFakeAppServerResponse(transport, id: .int(5151))
        XCTAssertEqual(release.result?["decision"]?.stringValue, "decline")

        for _ in 0..<200 where !events.contains(where: {
            if case .approvalResolved(let metadata) = $0 {
                return metadata.sessionID == "thr_stale_turn"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .approvalResolved(let metadata) = $0 {
                return metadata.sessionID == "thr_stale_turn"
            }
            return false
        })
        XCTAssertFalse(events.contains {
            if case .approvalRequest = $0 {
                return true
            }
            return false
        }, "旧 turn 的审批不应重新变成输入框上方的审批卡")

        socket.disconnect()
    }

    func testDirectRuntimeShowsOldApprovalWhenItsTurnIsStillActive() async throws {
        // 即便 approval 自带的 startedAtMs 很早，只要 app-server 当前仍把同一个 turn 报为等待审批，
        // runtime 就不能自动 decline/cancel；真实用户可能隔很久才回到 iPad 处理这个审批。
        let project = AgentProject(id: "proj_ancient", name: "Ancient", path: "/tmp/ancient")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let sessionTask = Task {
            try await client.session(id: "thr_ancient")
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        // 关键：active turn 就是旧审批所在的 turn（turn_ancient），按 turn 比对识别不出来。
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_ancient","sessionId":"thr_ancient","preview":"远古审批","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"active","activeFlags":["waitingOnApproval"]},"path":null,"cwd":"/tmp/ancient","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"远古审批","turns":[{"id":"turn_ancient","status":"inProgress","items":[]}]}}}"#)
        let sessionResponse = try await sessionTask.value
        XCTAssertEqual(sessionResponse.session.activeTurnID, "turn_ancient")

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }
        socket.connect(sessionID: "thr_ancient")

        let resumeMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let resume = try decodeAppServerRequest(resumeMessages[3])
        XCTAssertEqual(resume.method, "thread/resume")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"result":{"thread":{"id":"thr_ancient","sessionId":"thr_ancient","preview":"远古审批","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"active","activeFlags":["waitingOnApproval"]},"path":null,"cwd":"/tmp/ancient","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"远古审批","turns":[{"id":"turn_ancient","status":"inProgress","items":[]}]}}}"#)

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        // startedAtMs=1000 表示 1970 年。过去这里会被 10 分钟阈值自动 cancel，现在必须继续交给用户决定。
        transport.enqueue(#"{"id":6262,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_ancient","turnId":"turn_ancient","itemId":"cmd_ancient","startedAtMs":1000,"command":"/bin/zsh -lc 'xcrun devicectl list devices'","availableDecisions":["accept","cancel"]}}"#)

        for _ in 0..<200 where !events.contains(where: {
            if case .approvalRequest = $0 {
                return true
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .approvalRequest(let approval, let metadata) = $0 {
                return approval.id == "cmd_ancient" && metadata.sessionID == "thr_ancient"
            }
            return false
        }, "当前 active turn 的长时间等待审批仍应弹给用户处理")
        let sentMessages = await transport.sentMessages()
        XCTAssertFalse(sentMessages.contains { message in
            guard let response = try? AgentAPIClient.decoder.decode(
                CodexAppServerResponse.self,
                from: Data(message.utf8)
            ) else {
                return false
            }
            return response.id == .int(6262)
        }, "runtime 不应因 startedAtMs 很早自动回复审批")

        socket.disconnect()
    }

    func testDirectRuntimeRefreshesCachedActiveTurnBeforeDroppingOldReplayedApproval() async throws {
        let project = AgentProject(id: "proj_stale_cached_turn", name: "Stale Cached Turn", path: "/tmp/stale-cached-turn")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let sessionTask = Task {
            try await client.session(id: "thr_stale_cached_turn")
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_stale_cached_turn","sessionId":"thr_stale_cached_turn","preview":"缓存旧 turn","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490001,"status":{"type":"active","activeFlags":["waitingOnApproval"]},"path":null,"cwd":"/tmp/stale-cached-turn","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"缓存旧 turn","turns":[{"id":"turn_old","status":"inProgress","items":[]}]}}}"#)
        let sessionResponse = try await sessionTask.value
        XCTAssertEqual(sessionResponse.session.status, "waiting_for_approval")
        XCTAssertEqual(sessionResponse.session.activeTurnID, "turn_old")

        let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
        var statuses: [WebSocketStatus] = []
        var events: [AgentEvent] = []
        socket.onStatus = { statuses.append($0) }
        socket.onEvent = { events.append($0) }
        socket.connect(sessionID: "thr_stale_cached_turn")

        let resumeMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let resume = try decodeAppServerRequest(resumeMessages[3])
        XCTAssertEqual(resume.method, "thread/resume")
        // 真实现场里，app-server 可能同时保留旧审批 turn 和后来真正活跃的新 turn。
        // resume 返回 turns 时应以最新 inProgress 为准，不能让本地旧缓存继续覆盖当前 turn。
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resume.id)),"result":{"thread":{"id":"thr_stale_cached_turn","sessionId":"thr_stale_cached_turn","preview":"缓存旧 turn","ephemeral":false,"modelProvider":"openai","createdAt":1780490000,"updatedAt":1780490002,"status":{"type":"active","activeFlags":["waitingOnApproval"]},"path":null,"cwd":"/tmp/stale-cached-turn","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"缓存旧 turn","turns":[{"id":"turn_old","status":"inProgress","items":[]},{"id":"turn_middle","status":"completed","items":[]},{"id":"turn_current","status":"inProgress","items":[]}]}}}"#)

        for _ in 0..<200 where !statuses.contains(.connected) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(statuses.contains(.connected))

        transport.enqueue(#"{"id":6161,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_stale_cached_turn","turnId":"turn_old","itemId":"cmd_old","command":"/bin/zsh -lc 'xcrun devicectl list devices'"}}"#)

        let release = try await waitForFakeAppServerResponse(transport, id: .int(6161))
        XCTAssertEqual(release.result?["decision"]?.stringValue, "decline")

        for _ in 0..<200 where !events.contains(where: {
            if case .approvalResolved(let metadata) = $0 {
                return metadata.sessionID == "thr_stale_cached_turn"
            }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            if case .approvalResolved(let metadata) = $0 {
                return metadata.sessionID == "thr_stale_cached_turn"
            }
            return false
        })
        XCTAssertFalse(events.contains {
            if case .approvalRequest = $0 {
                return true
            }
            return false
        }, "缓存里的旧 activeTurnID 不应让旧审批重新显示成审批卡")

        socket.disconnect()
    }

    func testCodexAppServerSessionRuntimeReconnectsAfterTransportReceiveFailure() async throws {
        let project = AgentProject(id: "proj_direct_reconnect", name: "Direct Reconnect", path: "/tmp/direct-reconnect")
        let transportPool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transportPool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "",
                resumeID: "",
                clientMessageID: "client_reconnect_create"
            ))
        }

        let firstTransport = try await waitForFakeAppServerTransport(in: transportPool, index: 0)
        let initializeMessages = try await waitForFakeAppServerMessages(firstTransport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        firstTransport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let threadMessages = try await waitForFakeAppServerMessages(firstTransport, count: 3)
        let threadStart = try decodeAppServerRequest(threadMessages[2])
        XCTAssertEqual(threadStart.method, "thread/start")
        firstTransport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_reconnect","sessionId":"thr_reconnect","preview":"可重连会话","ephemeral":false,"modelProvider":"openai","createdAt":1780490200,"updatedAt":1780490201,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct-reconnect","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"直连重连","turns":[]}}}"#)

        let created = try await createTask.value
        XCTAssertEqual(created.session.id, "thr_reconnect")
        let isReadyAfterCreate = await runtime.hasReadyConnectionForTesting()
        XCTAssertTrue(isReadyAfterCreate)

        firstTransport.failReceive()
        try await waitForRuntimeConnectionToBecomeUnavailable(runtime)

        let reconnectTask = Task {
            try await runtime.connectForEvents(sessionID: "thr_reconnect")
        }
        let secondTransport = try await waitForFakeAppServerTransport(in: transportPool, index: 1)
        let reconnectInitializeMessages = try await waitForFakeAppServerMessages(secondTransport, count: 1)
        let reconnectInitialize = try decodeAppServerRequest(reconnectInitializeMessages[0])
        XCTAssertEqual(reconnectInitialize.method, "initialize")
        secondTransport.enqueue(#"{"id":\#(try jsonFragment(for: reconnectInitialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let reconnectHandshakeMessages = try await waitForFakeAppServerMessages(secondTransport, count: 2)
        let initialized = try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: Data(reconnectHandshakeMessages[1].utf8)
        )
        XCTAssertEqual(initialized.method, "initialized")

        // connectForEvents 本身就要按官方 app-server 客户端流程 thread/resume，建立当前连接的 live listener。
        // 不能等到下一次 turn/start 才 resume，否则历史 pending approval 和早到 turn 事件都可能丢在上游。
        let reconnectResumeMessages = try await waitForFakeAppServerMessages(secondTransport, count: 3)
        let reconnectResumeRequest = try decodeAppServerRequest(reconnectResumeMessages[2])
        XCTAssertEqual(reconnectResumeRequest.method, "thread/resume")
        XCTAssertEqual(reconnectResumeRequest.params?["threadId"]?.stringValue, "thr_reconnect")
        XCTAssertEqual(reconnectResumeRequest.params?["cwd"]?.stringValue, project.path)
        secondTransport.enqueue(#"{"id":\#(try jsonFragment(for: reconnectResumeRequest.id)),"result":{"thread":{"id":"thr_reconnect","sessionId":"thr_reconnect","preview":"可重连会话","ephemeral":false,"modelProvider":"openai","createdAt":1780490200,"updatedAt":1780490202,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct-reconnect","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"直连重连","turns":[]}}}"#)
        try await reconnectTask.value

        let turnTask = Task {
            try await runtime.startTurn(
                sessionID: "thr_reconnect",
                prompt: "断线后继续",
                clientMessageID: "client_reconnect_turn"
            )
        }
        let turnStart = try await waitForFakeAppServerRequest(secondTransport, method: "turn/start", after: 3)
        XCTAssertEqual(turnStart.method, "turn/start")
        let turnParams = try XCTUnwrap(turnStart.params?.objectValue)
        XCTAssertEqual(turnParams["threadId"]?.stringValue, "thr_reconnect")
        XCTAssertEqual(turnParams["cwd"]?.stringValue, project.path)
        XCTAssertEqual(turnParams["clientUserMessageId"]?.stringValue, "client_reconnect_turn")
        secondTransport.enqueue(#"{"id":\#(try jsonFragment(for: turnStart.id)),"result":{"turn":{"id":"turn_reconnect","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490202,"completedAt":null,"durationMs":null}}}"#)

        let turnID = try await turnTask.value
        XCTAssertEqual(turnID, "turn_reconnect")
        let firstSentMessages = await firstTransport.sentMessages()
        let secondSentMessages = await secondTransport.sentMessages()
        XCTAssertEqual(firstSentMessages.count, 3)
        XCTAssertTrue(secondSentMessages.count >= 4)
        let secondRequests = secondSentMessages.compactMap { try? decodeAppServerRequest($0) }
        XCTAssertEqual(secondRequests.filter { $0.method == "thread/resume" }.count, 1)
        XCTAssertEqual(secondRequests.filter { $0.method == "turn/start" }.count, 1)
    }

    func testCodexAppServerSessionRuntimeRetiresConnectionAfterTurnStartTimeout() async throws {
        let project = AgentProject(id: "proj_turn_timeout", name: "Turn Timeout", path: "/tmp/turn-timeout")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            requestTimeout: 0.05,
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        let pageTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let firstTransport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let initializeMessages = try await waitForFakeAppServerMessages(firstTransport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transportResponse(firstTransport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let listMessages = try await waitForFakeAppServerMessages(firstTransport, count: 3)
        let listRequest = try decodeAppServerRequest(listMessages[2])
        XCTAssertEqual(listRequest.method, "thread/list")
        transportResponse(firstTransport, id: listRequest.id, result: #"{"data":[{"id":"thr_turn_timeout","sessionId":"thr_turn_timeout","preview":"超时会话","ephemeral":false,"modelProvider":"openai","createdAt":1780490700,"updatedAt":1780490701,"status":{"type":"idle"},"path":null,"cwd":"/tmp/turn-timeout","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"超时会话","turns":[]}],"nextCursor":null,"backwardsCursor":null}"#)
        _ = try await pageTask.value

        let timeoutTask = Task {
            try await runtime.startTurn(sessionID: "thr_turn_timeout", prompt: "这次会超时", clientMessageID: "client_timeout")
        }
        let firstResumeMessages = try await waitForFakeAppServerMessages(firstTransport, count: 4)
        let firstResume = try decodeAppServerRequest(firstResumeMessages[3])
        XCTAssertEqual(firstResume.method, "thread/resume")
        transportResponse(firstTransport, id: firstResume.id, result: #"{"thread":{"id":"thr_turn_timeout","sessionId":"thr_turn_timeout","preview":"超时会话","ephemeral":false,"modelProvider":"openai","createdAt":1780490700,"updatedAt":1780490702,"status":{"type":"idle"},"path":null,"cwd":"/tmp/turn-timeout","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"超时会话","turns":[]}}"#)

        let firstTurnMessages = try await waitForFakeAppServerMessages(firstTransport, count: 5)
        let firstTurnStart = try decodeAppServerRequest(firstTurnMessages[4])
        XCTAssertEqual(firstTurnStart.method, "turn/start")

        do {
            _ = try await timeoutTask.value
            XCTFail("turn/start timeout should fail")
        } catch CodexAppServerConnectionError.timeout(let method, _) {
            XCTAssertEqual(method, "turn/start")
        } catch {
            XCTFail("Unexpected timeout error: \(error)")
        }

        let retryTask = Task {
            try await runtime.startTurn(sessionID: "thr_turn_timeout", prompt: "新连接继续", clientMessageID: "client_after_timeout")
        }
        let secondTransport = try await waitForFakeAppServerTransport(in: pool, index: 1)
        let secondInitializeMessages = try await waitForFakeAppServerMessages(secondTransport, count: 1)
        let secondInitialize = try decodeAppServerRequest(secondInitializeMessages[0])
        transportResponse(secondTransport, id: secondInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let secondResumeMessages = try await waitForFakeAppServerMessages(secondTransport, count: 3)
        let secondResume = try decodeAppServerRequest(secondResumeMessages[2])
        XCTAssertEqual(secondResume.method, "thread/resume")
        XCTAssertEqual(secondResume.params?["threadId"]?.stringValue, "thr_turn_timeout")
        transportResponse(secondTransport, id: secondResume.id, result: #"{"thread":{"id":"thr_turn_timeout","sessionId":"thr_turn_timeout","preview":"超时会话","ephemeral":false,"modelProvider":"openai","createdAt":1780490700,"updatedAt":1780490703,"status":{"type":"idle"},"path":null,"cwd":"/tmp/turn-timeout","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"超时会话","turns":[]}}"#)

        let secondTurnMessages = try await waitForFakeAppServerMessages(secondTransport, count: 4)
        let secondTurnStart = try decodeAppServerRequest(secondTurnMessages[3])
        XCTAssertEqual(secondTurnStart.method, "turn/start")
        XCTAssertEqual(secondTurnStart.params?["clientUserMessageId"]?.stringValue, "client_after_timeout")
        transportResponse(secondTransport, id: secondTurnStart.id, result: #"{"turn":{"id":"turn_after_timeout","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490704,"completedAt":null,"durationMs":null}}"#)

        let retryTurnID = try await retryTask.value
        XCTAssertEqual(retryTurnID, "turn_after_timeout")
    }

    func testCodexAppServerSessionRuntimeRefreshesUnavailableGatewayConfigBeforeConnecting() async throws {
        let project = AgentProject(id: "proj_cold_start", name: "Cold Start", path: "/tmp/cold-start")
        let configProvider = SequencedDirectConfigProvider([
            makeDirectAppServerConfig(project: project, gatewayAvailable: false),
            makeDirectAppServerConfig(project: project, gatewayAvailable: true)
        ])
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { try await configProvider.next() }
        )

        let pageTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let listMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let listRequest = try decodeAppServerRequest(listMessages[2])
        XCTAssertEqual(listRequest.method, "thread/list")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: listRequest.id)),"result":{"data":[{"id":"thr_cold_start","sessionId":"thr_cold_start","preview":"首启恢复","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"idle"},"path":null,"cwd":"/tmp/cold-start","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"首启恢复","turns":[]}],"nextCursor":null,"backwardsCursor":null}}"#)

        let page = try await pageTask.value
        XCTAssertEqual(configProvider.callCount, 2)
        XCTAssertEqual(page.sessions.map(\.id), ["thr_cold_start"])
    }

    func testCodexAppServerSessionRuntimeListsRootProjectForChildWorkspace() async throws {
        let project = AgentProject(id: "proj_root_list", name: "Root List", path: "/tmp/root-list")
        let childWorkspace = AgentWorkspace(
            id: "ws_root_list_child",
            name: "ios",
            path: "/tmp/root-list/apps/ios",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let worktreeWorkspace = AgentWorkspace(
            id: "ws_root_list_worktree",
            name: "feature",
            path: "/tmp/mimi-worktrees/root-list-feature",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        let childPageTask = Task {
            try await runtime.sessionsPage(workspace: childWorkspace, cursor: nil, limit: 20)
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let childMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let childList = try decodeAppServerRequest(childMessages[2])
        XCTAssertEqual(childList.method, "thread/list")
        XCTAssertEqual(childList.params?.objectValue?["cwd"]?.stringValue, project.path)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: childList.id)),"result":{"data":[{"id":"thr_child_root_history","sessionId":"thr_child_root_history","preview":"root history","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"notLoaded"},"path":null,"cwd":"/tmp/root-list","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Root history","turns":[]}],"nextCursor":null,"backwardsCursor":null}}"#)

        let childPage = try await childPageTask.value
        XCTAssertEqual(childPage.sessions.map(\.id), ["thr_child_root_history"])

        let worktreePageTask = Task {
            try await runtime.sessionsPage(workspace: worktreeWorkspace, cursor: nil, limit: 20)
        }

        let worktreeMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let worktreeList = try decodeAppServerRequest(worktreeMessages[3])
        XCTAssertEqual(worktreeList.method, "thread/list")
        XCTAssertEqual(worktreeList.params?.objectValue?["cwd"]?.stringValue, worktreeWorkspace.path)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: worktreeList.id)),"result":{"data":[],"nextCursor":null,"backwardsCursor":null}}"#)

        let worktreePage = try await worktreePageTask.value
        XCTAssertTrue(worktreePage.sessions.isEmpty)
    }

    func testSessionStoreConsumesDirectAppServerEventsWithoutMobileProtocolConversion() async throws {
        let project = AgentProject(id: "proj_store_direct", name: "Store Direct", path: "/tmp/store-direct")
        let config = makeDirectAppServerConfig(project: project)
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { config }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)
        let appStore = AppStore()
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        let contextStore = SessionContextStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: logStore,
            contextStore: contextStore,
            clientFactory: { client },
            webSocketFactory: { CodexAppServerSessionWebSocketClient(runtime: runtime) },
            webSocketReconnectDelayNanoseconds: { _ in 1_000_000 }
        )

        store.selectedProjectID = project.id
        let refreshTask = Task { await store.refreshAll(autoAttach: false) }
        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)
        let listMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let listRequest = try decodeAppServerRequest(listMessages[2])
        XCTAssertEqual(listRequest.method, "thread/list")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: listRequest.id)),"result":{"data":[],"nextCursor":null,"backwardsCursor":null}}"#)
        await refreshTask.value
        XCTAssertEqual(store.selectedProjectID, project.id)

        let sendTask = Task { await store.sendPrompt("帮我验收 direct Store") }
        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let modelList = try decodeAppServerRequest(threadMessages[3])
        XCTAssertEqual(modelList.method, "model/list")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: modelList.id)),"result":{"models":[{"id":"gpt-store-default","name":"Store Default","provider":"openai","isDefault":true}]}}"#)

        let threadStartMessages = try await waitForFakeAppServerMessages(transport, count: 5)
        let threadStart = try decodeAppServerRequest(threadStartMessages[4])
        XCTAssertEqual(threadStart.method, "thread/start")
        XCTAssertNil(threadStart.params?.objectValue?["model"]?.stringValue)
        XCTAssertNil(threadStart.params?.objectValue?["modelProvider"])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_store_direct","sessionId":"thr_store_direct","preview":"帮我验收 direct Store","ephemeral":false,"modelProvider":"openai","createdAt":1780490100,"updatedAt":1780490101,"status":{"type":"idle"},"path":null,"cwd":"/tmp/store-direct","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Store 直连","turns":[]}}}"#)

        let turnMessages = try await waitForFakeAppServerMessages(transport, count: 6)
        let turnStart = try decodeAppServerRequest(turnMessages[5])
        XCTAssertEqual(turnStart.method, "turn/start")
        XCTAssertEqual(turnStart.params?.objectValue?["model"]?.stringValue, "gpt-store-default")
        let collaborationMode = try XCTUnwrap(turnStart.params?.objectValue?["collaborationMode"]?.objectValue)
        XCTAssertEqual(collaborationMode["mode"]?.stringValue, "default")
        XCTAssertEqual(collaborationMode["settings"]?.objectValue?["model"]?.stringValue, "gpt-store-default")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: turnStart.id)),"result":{"turn":{"id":"turn_store_direct","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490102,"completedAt":null,"durationMs":null}}}"#)
        let historyMessages = try await waitForFakeAppServerMessages(transport, count: 7)
        let historyRead = try decodeAppServerRequest(historyMessages[6])
        XCTAssertEqual(historyRead.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: historyRead.id)),"result":{"thread":{"id":"thr_store_direct","sessionId":"thr_store_direct","preview":"帮我验收 direct Store","ephemeral":false,"modelProvider":"openai","createdAt":1780490100,"updatedAt":1780490102,"status":{"type":"active","activeFlags":[]},"path":null,"cwd":"/tmp/store-direct","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Store 直连","turns":[]}}}"#)
        let didSend = await sendTask.value
        XCTAssertTrue(didSend)
        try await waitForWebSocketStatus(.connected, store: store)
        XCTAssertEqual(store.selectedSessionID, "thr_store_direct")

        transport.enqueue(#"{"method":"item/agentMessage/delta","params":{"threadId":"thr_store_direct","turnId":"turn_store_direct","itemId":"assistant_store","delta":"阶段一"}}"#)
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: "thr_store_direct") {
            $0.contains { $0.role == .assistant && $0.content.contains("阶段一") }
        }

        transport.enqueue(#"{"method":"item/completed","params":{"threadId":"thr_store_direct","turnId":"turn_store_direct","item":{"type":"agentMessage","id":"assistant_store","text":"最终回答"}}}"#)
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: "thr_store_direct") {
            $0.contains { $0.role == .assistant && $0.content == "最终回答" }
        }

        transport.enqueue(#"{"method":"item/commandExecution/outputDelta","params":{"threadId":"thr_store_direct","turnId":"turn_store_direct","itemId":"cmd_store","delta":"go test ok\n","stream":"stdout"}}"#)
        for _ in 0..<300 where !logStore.log(for: "thr_store_direct").contains("go test ok") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(logStore.log(for: "thr_store_direct").contains("go test ok"))

        transport.enqueue(#"{"method":"turn/diff/updated","params":{"threadId":"thr_store_direct","turnId":"turn_store_direct","path":"Sources/App.swift","status":"modified"}}"#)
        for _ in 0..<300 where contextStore.context(for: "thr_store_direct")?.tasks.contains(where: { $0.kind == "file_change" && $0.subtitle == "Sources/App.swift" }) != true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(contextStore.context(for: "thr_store_direct")?.tasks.contains { $0.kind == "file_change" && $0.subtitle == "Sources/App.swift" } == true)
        XCTAssertFalse(conversationStore.messages(for: "thr_store_direct").contains { $0.kind == .fileChangeSummary })

        transport.enqueue(#"{"method":"item/completed","params":{"threadId":"thr_store_direct","turnId":"turn_store_direct","item":{"type":"fileChange","id":"file_change_store","status":"modified","changes":[{"path":"Sources/App.swift","kind":"modified"}]}}}"#)
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: "thr_store_direct") {
            $0.contains { $0.kind == .fileChangeSummary && $0.content.contains("Sources/App.swift") }
        }
        XCTAssertEqual(conversationStore.messages(for: "thr_store_direct").filter { $0.kind == .fileChangeSummary }.count, 1)

        transport.enqueue(#"{"id":101,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_store_direct","turnId":"turn_store_direct","itemId":"cmd_store","command":"go test ./..."}}"#)
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: "thr_store_direct") {
            $0.contains { $0.kind == .approval && $0.content.contains("等待审批") }
        }
        store.decideApproval(ApprovalSummary(id: "cmd_store", title: "运行 go test", kind: "command", count: 1), accept: true)
        let approvalResponse = try await waitForFakeAppServerResponse(transport, id: .int(101))
        XCTAssertEqual(approvalResponse.id, .int(101))
        XCTAssertEqual(approvalResponse.result?["decision"]?.stringValue, "accept")

        transport.enqueue(#"{"method":"turn/completed","params":{"threadId":"thr_store_direct","turnId":"turn_store_direct"}}"#)
        for _ in 0..<200 where store.selectedForegroundActivity != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(store.selectedForegroundActivity)
    }

    func testDirectIdleHistorySessionSendsThroughResumePath() async throws {
        let project = AgentProject(id: "proj_direct_history", name: "Direct History", path: "/tmp/direct-history")
        let config = makeDirectAppServerConfig(project: project)
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { config }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { CodexAppServerSessionWebSocketClient(runtime: runtime) },
            webSocketReconnectDelayNanoseconds: { _ in 1_000_000 }
        )

        store.selectedProjectID = project.id
        let refreshTask = Task { await store.refreshAll(autoAttach: false) }
        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let listMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let listRequest = try decodeAppServerRequest(listMessages[2])
        XCTAssertEqual(listRequest.method, "thread/list")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: listRequest.id)),"result":{"data":[{"id":"thr_idle_history","sessionId":"thr_idle_history","preview":"历史 idle","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct-history","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"历史 idle","turns":[]}],"nextCursor":null,"backwardsCursor":null}}"#)
        await refreshTask.value

        let historySession = try XCTUnwrap(store.filteredSessions.first)
        XCTAssertEqual(historySession.id, "thr_idle_history")
        XCTAssertEqual(historySession.status, "history")
        XCTAssertFalse(historySession.isRunning)

        let selectTask = Task { await store.selectSession(historySession) }
        let historyReadMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let historyRead = try decodeAppServerRequest(historyReadMessages[3])
        XCTAssertEqual(historyRead.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: historyRead.id)),"result":{"thread":{"id":"thr_idle_history","sessionId":"thr_idle_history","preview":"历史 idle","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct-history","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"历史 idle","turns":[]}}}"#)
        await selectTask.value

        // 选中历史会话现在也会立即建立事件订阅：先在当前连接补一次 thread/resume。
        let subscriptionResumeMessages = try await waitForFakeAppServerMessages(transport, count: 5)
        let subscriptionResume = try decodeAppServerRequest(subscriptionResumeMessages[4])
        XCTAssertEqual(subscriptionResume.method, "thread/resume")
        XCTAssertEqual(subscriptionResume.params?.objectValue?["threadId"]?.stringValue, "thr_idle_history")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: subscriptionResume.id)),"result":{"thread":{"id":"thr_idle_history","sessionId":"thr_idle_history","preview":"历史 idle","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct-history","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"历史 idle","turns":[]}}}"#)

        // 订阅建立后会异步刷新 thread 目标；回空结果即可。
        let goalMessages = try await waitForFakeAppServerMessages(transport, count: 6)
        let goalGet = try decodeAppServerRequest(goalMessages[5])
        XCTAssertEqual(goalGet.method, "thread/goal/get")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: goalGet.id)),"result":{}}"#)

        let sendTask = Task { await store.sendPrompt("继续排查") }
        let resumeMessages = try await waitForFakeAppServerMessages(transport, count: 7)
        let modelList = try decodeAppServerRequest(resumeMessages[6])
        XCTAssertEqual(modelList.method, "model/list")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: modelList.id)),"result":{"models":[{"id":"gpt-history-default","name":"History Default","provider":"openai","isDefault":true}]}}"#)

        let resumeRequestMessages = try await waitForFakeAppServerMessages(transport, count: 8)
        let resumeRequest = try decodeAppServerRequest(resumeRequestMessages[7])
        XCTAssertEqual(resumeRequest.method, "thread/resume")
        XCTAssertEqual(resumeRequest.params?.objectValue?["threadId"]?.stringValue, "thr_idle_history")
        XCTAssertNil(resumeRequest.params?.objectValue?["model"]?.stringValue)
        XCTAssertNil(resumeRequest.params?.objectValue?["modelProvider"])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resumeRequest.id)),"result":{"thread":{"id":"thr_idle_history","sessionId":"thr_idle_history","preview":"继续排查","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490302,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct-history","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"历史 idle","turns":[]}}}"#)

        let turnMessages = try await waitForFakeAppServerMessages(transport, count: 9)
        let turnStart = try decodeAppServerRequest(turnMessages[8])
        XCTAssertEqual(turnStart.method, "turn/start")
        XCTAssertEqual(turnStart.params?.objectValue?["threadId"]?.stringValue, "thr_idle_history")
        XCTAssertEqual(turnStart.params?.objectValue?["clientUserMessageId"]?.stringValue?.isEmpty, false)
        XCTAssertEqual(turnStart.params?.objectValue?["model"]?.stringValue, "gpt-history-default")
        let collaborationMode = try XCTUnwrap(turnStart.params?.objectValue?["collaborationMode"]?.objectValue)
        XCTAssertEqual(collaborationMode["mode"]?.stringValue, "default")
        XCTAssertEqual(collaborationMode["settings"]?.objectValue?["model"]?.stringValue, "gpt-history-default")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: turnStart.id)),"result":{"turn":{"id":"turn_idle_history","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490303,"completedAt":null,"durationMs":null}}}"#)

        let sent = await sendTask.value
        XCTAssertTrue(sent)
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: "thr_idle_history") {
            $0.contains { $0.content == "已继续这个历史会话。" }
        }
    }

    func testStartTurnResumesThreadOnConnectionBeforeFirstTurnStart() async throws {
        // idle 历史 thread 会进入 runtime 的上下文缓存。若 startTurn 不先在当前 gateway 连接上
        // thread/resume，app-server 不会回推这个 thread 的 turn 事件。这里锁定修复：首次
        // turn/start 前必须补一次 thread/resume，且同一连接内不再重复 resume。
        let project = AgentProject(id: "proj_resume_guard", name: "Resume Guard", path: "/tmp/resume-guard")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        // thread/list 把 idle thread 灌进 contextsBySessionID，但不会把它登记成「已在本连接 resume」。
        let pageTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)
        let listMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let listRequest = try decodeAppServerRequest(listMessages[2])
        XCTAssertEqual(listRequest.method, "thread/list")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: listRequest.id)),"result":{"data":[{"id":"thr_idle_guard","sessionId":"thr_idle_guard","preview":"上次的会话","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490301,"status":{"type":"idle"},"path":null,"cwd":"/tmp/resume-guard","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"上次的会话","turns":[]}],"nextCursor":null,"backwardsCursor":null}}"#)
        let page = try await pageTask.value
        XCTAssertEqual(page.sessions.map(\.id), ["thr_idle_guard"])
        XCTAssertFalse(try XCTUnwrap(page.sessions.first).isRunning, "idle 历史 thread 在列表语义上应保持 history，但 runtime startTurn 仍需要先 resume")

        // 第一次直连发送：startTurn 必须先 thread/resume，再 turn/start。
        let firstTurnTask = Task {
            try await runtime.startTurn(sessionID: "thr_idle_guard", prompt: "继续上次", clientMessageID: nil)
        }
        let resumeMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let resumeRequest = try decodeAppServerRequest(resumeMessages[3])
        XCTAssertEqual(resumeRequest.method, "thread/resume", "首次 turn/start 前应先在当前连接 resume thread")
        XCTAssertEqual(resumeRequest.params?["threadId"]?.stringValue, "thr_idle_guard")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resumeRequest.id)),"result":{"thread":{"id":"thr_idle_guard","sessionId":"thr_idle_guard","preview":"上次的会话","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490302,"status":{"type":"idle"},"path":null,"cwd":"/tmp/resume-guard","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"上次的会话","turns":[]}}}"#)

        let firstTurnMessages = try await waitForFakeAppServerMessages(transport, count: 5)
        let firstTurnStart = try decodeAppServerRequest(firstTurnMessages[4])
        XCTAssertEqual(firstTurnStart.method, "turn/start")
        XCTAssertEqual(firstTurnStart.params?["threadId"]?.stringValue, "thr_idle_guard")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: firstTurnStart.id)),"result":{"turn":{"id":"turn_resume_guard","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490303,"completedAt":null,"durationMs":null}}}"#)
        let firstTurnID = try await firstTurnTask.value
        XCTAssertEqual(firstTurnID, "turn_resume_guard")

        // 同一连接内第二次发送不应再 resume，只发 turn/start。
        let secondTurnTask = Task {
            try await runtime.startTurn(sessionID: "thr_idle_guard", prompt: "再来一次", clientMessageID: nil)
        }
        let secondTurnMessages = try await waitForFakeAppServerMessages(transport, count: 6)
        let secondTurnStart = try decodeAppServerRequest(secondTurnMessages[5])
        XCTAssertEqual(secondTurnStart.method, "turn/start", "已在本连接 resume 过的 thread 不应重复 resume")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: secondTurnStart.id)),"result":{"turn":{"id":"turn_resume_guard_2","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490304,"completedAt":null,"durationMs":null}}}"#)
        let secondTurnID = try await secondTurnTask.value
        XCTAssertEqual(secondTurnID, "turn_resume_guard_2")

        let allMessages = await transport.sentMessages()
        let resumeCount = allMessages.filter { (try? decodeAppServerRequest($0))?.method == "thread/resume" }.count
        XCTAssertEqual(resumeCount, 1, "同一连接内只应 resume 一次")
    }

    func testCodexAppServerSessionRuntimeRequiresProjectForThreadList() async throws {
        let project = AgentProject(id: "proj_direct_required", name: "Direct Required", path: "/tmp/direct-required")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "agent-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        do {
            _ = try await runtime.sessionsPage(projectID: nil, cursor: nil, limit: 20)
            XCTFail("direct thread/list 必须绑定 allowlist project")
        } catch CodexAppServerSessionRuntimeError.projectRequired {
            let sentMessages = await transport.sentMessages()
            XCTAssertTrue(sentMessages.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCodexAppServerProjectorMapsCommonNotifications() throws {
        var projector = CodexAppServerEventProjector()

        let started = try decodeAppServerNotification(#"{"method":"turn/started","params":{"threadId":"thr_demo","turn":{"id":"turn_demo"}}}"#)
        if case .turnStarted(let meta) = try XCTUnwrap(projector.project(started)) {
            XCTAssertEqual(meta.sessionID, "thr_demo")
            XCTAssertEqual(meta.turnID, "turn_demo")
        } else {
            XCTFail("Expected turnStarted")
        }

        let delta = try decodeAppServerNotification(#"{"method":"item/agentMessage/delta","params":{"threadId":"thr_demo","turnId":"turn_demo","itemId":"assistant_1","delta":"hello"}}"#)
        if case .assistantDelta(let payload, let meta) = try XCTUnwrap(projector.project(delta)) {
            XCTAssertEqual(payload.text, "hello")
            XCTAssertEqual(payload.role, .assistant)
            XCTAssertEqual(meta.messageID, "appserver:turn_demo:assistant_1")
        } else {
            XCTFail("Expected assistantDelta")
        }

        let commandStarted = try decodeAppServerNotification(#"{"method":"item/started","params":{"threadId":"thr_demo","turnId":"turn_demo","item":{"type":"commandExecution","id":"cmd_1","command":"go test ./...","cwd":"/tmp/demo","status":"inProgress"}}}"#)
        if case .sessionContext(let context, let meta) = try XCTUnwrap(projector.project(commandStarted)) {
            XCTAssertEqual(meta.sessionID, "thr_demo")
            XCTAssertEqual(context.tasks.first?.kind, "command")
            XCTAssertEqual(context.tasks.first?.title, "go test ./...")
            XCTAssertEqual(context.tasks.first?.status, "inProgress")
        } else {
            XCTFail("Expected command started sessionContext")
        }

        let completed = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_demo","turnId":"turn_demo","item":{"type":"agentMessage","id":"assistant_1","text":"hello world"}}}"#)
        if case .messageCompleted(let message, let meta) = try XCTUnwrap(projector.project(completed)) {
            XCTAssertEqual(message.id, "appserver:turn_demo:assistant_1")
            XCTAssertEqual(message.sessionID, "thr_demo")
            XCTAssertEqual(message.content, "hello world")
            XCTAssertEqual(message.role, .assistant)
            XCTAssertEqual(message.kind, .message)
            XCTAssertEqual(message.sendStatus, .confirmed)
            XCTAssertEqual(meta.itemID, "assistant_1")
        } else {
            XCTFail("Expected messageCompleted")
        }

        let commentary = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_demo","turnId":"turn_demo","item":{"type":"agentMessage","id":"commentary_1","text":"我先检查上下文。","phase":"commentary"}}}"#)
        if case .messageCompleted(let message, _) = try XCTUnwrap(projector.project(commentary)) {
            XCTAssertEqual(message.role, .system)
            XCTAssertEqual(message.kind, .reasoningSummary)
            XCTAssertEqual(message.content, "我先检查上下文。")
        } else {
            XCTFail("Expected commentary messageCompleted")
        }

        let planCompleted = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_demo","turnId":"turn_demo","item":{"type":"plan","id":"plan_1","text":"检查上下文并给出答案。"}}}"#)
        if case .processItemCompleted(let message, let context, _) = try XCTUnwrap(projector.project(planCompleted)) {
            XCTAssertEqual(message.id, "appserver:turn_demo:plan_1")
            XCTAssertEqual(message.role, .system)
            XCTAssertEqual(message.kind, .plan)
            XCTAssertEqual(message.content, "检查上下文并给出答案。")
            XCTAssertNil(context)
        } else {
            XCTFail("Expected plan processItemCompleted")
        }

        let commandCompleted = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_demo","turnId":"turn_demo","item":{"type":"commandExecution","id":"cmd_1","command":"go test ./...","cwd":"/tmp/demo","status":"completed","commandActions":[{"name":"read","path":"README.md"}],"aggregatedOutput":"ok","exitCode":0}}}"#)
        if case .processItemCompleted(let message, let context, _) = try XCTUnwrap(projector.project(commandCompleted)) {
            XCTAssertEqual(message.role, .system)
            XCTAssertEqual(message.kind, .commandSummary)
            XCTAssertTrue(message.content.contains("命令：go test ./..."))
            XCTAssertTrue(message.content.contains("输出：\nok"))
            XCTAssertEqual(message.activityPayload?.category, .runCommand)
            XCTAssertEqual(message.activityPayload?.displayTitle, "查看 README.md")
            XCTAssertEqual(message.activityPayload?.cwd, "/tmp/demo")
            XCTAssertEqual(message.activityPayload?.exitCode, 0)
            XCTAssertEqual(context?.tasks.first?.kind, "command")
            XCTAssertEqual(context?.tasks.first?.status, "completed")
        } else {
            XCTFail("Expected command processItemCompleted")
        }

        let toolCompleted = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_demo","turnId":"turn_demo","item":{"type":"dynamicToolCall","id":"tool_1","namespace":"browser","tool":"open","status":"completed"}}}"#)
        if case .processItemCompleted(let message, let context, _) = try XCTUnwrap(projector.project(toolCompleted)) {
            XCTAssertEqual(message.role, .system)
            XCTAssertEqual(message.kind, .commandSummary)
            XCTAssertEqual(message.content, "工具：browser.open\n状态：completed")
            XCTAssertEqual(message.activityPayload?.category, .toolCall)
            XCTAssertEqual(message.activityPayload?.displayTitle, "browser.open")
            XCTAssertEqual(context?.tasks.first?.kind, "dynamic_tool")
            XCTAssertEqual(context?.tasks.first?.title, "browser.open")
            XCTAssertEqual(context?.tasks.first?.status, "completed")
        } else {
            XCTFail("Expected tool completed processItemCompleted")
        }

        let log = try decodeAppServerNotification(#"{"method":"item/commandExecution/outputDelta","params":{"threadId":"thr_demo","turnId":"turn_demo","itemId":"cmd_1","delta":"go test output","stream":"stdout"}}"#)
        if case .logDelta(let payload, _) = try XCTUnwrap(projector.project(log)) {
            XCTAssertEqual(payload.text, "go test output")
            XCTAssertEqual(payload.stream, "stdout")
        } else {
            XCTFail("Expected logDelta")
        }

        let diff = try decodeAppServerNotification(#"{"method":"turn/diff/updated","params":{"threadId":"thr_demo","turnId":"turn_demo","path":"Sources/App.swift","status":"modified","additions":2,"deletions":1}}"#)
        if case .sessionContext(let context, let meta) = try XCTUnwrap(projector.project(diff)) {
            XCTAssertEqual(meta.sessionID, "thr_demo")
            XCTAssertEqual(context.tasks.first?.kind, "file_change")
            XCTAssertEqual(context.tasks.first?.subtitle, "Sources/App.swift")
            XCTAssertEqual(context.tasks.first?.status, "modified")
        } else {
            XCTFail("Expected file change sessionContext")
        }

        let turnCompleted = try decodeAppServerNotification(#"{"method":"turn/completed","params":{"threadId":"thr_demo","turnId":"turn_demo"}}"#)
        if case .turnCompleted(let meta) = try XCTUnwrap(projector.project(turnCompleted)) {
            XCTAssertEqual(meta.sessionID, "thr_demo")
            XCTAssertEqual(meta.turnID, "turn_demo")
        } else {
            XCTFail("Expected turnCompleted")
        }

        let requestResolved = try decodeAppServerNotification(#"{"method":"serverRequest/resolved","params":{"threadId":"thr_demo","requestId":99}}"#)
        if case .approvalResolved(let meta) = try XCTUnwrap(projector.project(requestResolved)) {
            XCTAssertEqual(meta.sessionID, "thr_demo")
            XCTAssertEqual(meta.itemID, "99")
        } else {
            XCTFail("Expected approvalResolved")
        }

        let warning = try decodeAppServerNotification(#"{"method":"warning","params":{"threadId":"thr_demo","message":"rate limit soon","code":"rate_limit"}}"#)
        if case .warning(let payload, let meta) = try XCTUnwrap(projector.project(warning)) {
            XCTAssertEqual(payload.message, "rate limit soon")
            XCTAssertEqual(payload.code, "rate_limit")
            XCTAssertEqual(meta.sessionID, "thr_demo")
        } else {
            XCTFail("Expected warning")
        }

        let error = try decodeAppServerNotification(#"{"method":"error","params":{"message":"boom"}}"#)
        if case .error(let message) = try XCTUnwrap(projector.project(error)) {
            XCTAssertEqual(message, "boom")
        } else {
            XCTFail("Expected error")
        }
    }

    func testAgentEventDecodesSessionContextAlternateKeys() throws {
        let event = try AgentAPIClient.decoder.decode(
            AgentEvent.self,
            from: Data("""
            {
              "type": "session_context",
              "meta": {"session_id": "codex_thr_parent"},
              "context": {
                "session_id": "codex_thr_parent",
                "thread_id": "thr_parent",
                "status": {"type": "active", "activeFlags": ["waitingOnApproval"]},
                "git": {"branch": "codex/status-sidebar", "originUrl": "https://example.test/repo.git"},
                "subagents": [
                  {"id": "thr_child", "parentThreadId": "thr_parent", "nickname": "Noether", "role": "review"}
                ]
              }
            }
            """.utf8)
        )

        guard case .sessionContext(let context, let metadata) = event else {
            return XCTFail("Expected sessionContext event")
        }
        XCTAssertEqual(metadata.sessionID, "codex_thr_parent")
        XCTAssertEqual(context.status?.activeFlags, ["waitingOnApproval"])
        XCTAssertEqual(context.git?.originURL, "https://example.test/repo.git")
        XCTAssertEqual(context.subagents.first?.parentThreadID, "thr_parent")
    }

    func testSessionContextStoreMergesUpdatesAndAttachesSubagents() {
        let store = SessionContextStore()
        store.upsert(
            SessionContextSnapshot(
                sessionID: "thr_parent",
                threadID: "thr_parent",
                status: SessionContextStatus(type: "idle"),
                environment: SessionContextEnvironment(id: "local", kind: "local", label: "本地", cwd: "/tmp/parent", provider: "openai"),
                sources: [SessionContextSource(id: "session_source", kind: "session", label: "appServer")]
            ),
            fallbackSessionID: nil
        )
        store.upsert(
            SessionContextSnapshot(
                sessionID: "thr_parent",
                status: SessionContextStatus(type: "active", activeFlags: ["waitingOnApproval"]),
                tasks: [SessionContextTask(id: "cmd_1", kind: "command", title: "go test ./...", subtitle: "/tmp/parent", status: "running")]
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
                        nickname: "Noether",
                        role: "review",
                        status: "running"
                    )
                ]
            ),
            fallbackSessionID: nil
        )

        let parent = store.context(for: "thr_parent")
        XCTAssertEqual(parent?.status?.activeFlags, ["waitingOnApproval"])
        XCTAssertEqual(parent?.environment?.cwd, "/tmp/parent")
        XCTAssertEqual(parent?.tasks.first?.title, "go test ./...")
        XCTAssertEqual(parent?.subagents.first?.displayName, "Noether")
        XCTAssertEqual(store.context(for: "codex_thr_parent")?.subagents.first?.id, "thr_child")
    }

    func testSessionContextStoreClearsPendingApprovalTasks() {
        let store = SessionContextStore()
        store.upsert(
            SessionContextSnapshot(
                sessionID: "thr_approval_tasks",
                status: SessionContextStatus(type: "active", activeFlags: ["waitingOnApproval"]),
                tasks: [
                    SessionContextTask(id: "cmd_waiting", kind: "command", title: "Agent 请求执行命令：curl -I https://example.com", subtitle: "high", status: "waiting"),
                    SessionContextTask(id: "cmd_running", kind: "command", title: "go test ./...", subtitle: nil, status: "running")
                ]
            ),
            fallbackSessionID: nil
        )

        store.clearPendingApprovalTasks(sessionID: "thr_approval_tasks")

        let context = store.context(for: "thr_approval_tasks")
        XCTAssertEqual(context?.tasks.map(\.id), ["cmd_running"])
        XCTAssertEqual(context?.status?.activeFlags, ["waitingOnApproval"])
    }

    func testCodexAppServerRequestBuildersUseRemoteSafeDefaults() throws {
        let project = AgentProject(id: "proj_safe", name: "Safe", path: "/tmp/safe-project")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])

        let threadStart = try builder.threadStart(projectID: project.id)
        XCTAssertEqual(threadStart.method, "thread/start")
        let threadParams = try XCTUnwrap(threadStart.params?.objectValue)
        XCTAssertEqual(threadParams["cwd"]?.stringValue, project.path)
        XCTAssertNil(threadParams["model"]?.stringValue)
        XCTAssertEqual(threadParams["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(threadParams["approvalsReviewer"]?.stringValue, "user")
        XCTAssertEqual(threadParams["sandbox"]?.stringValue, "danger-full-access")
        XCTAssertNil(threadParams["runtimeWorkspaceRoots"])

        let turnStart = try builder.turnStart(
            threadID: "thr_safe",
            projectID: project.id,
            prompt: "只回复 ok",
            clientMessageID: "client_safe"
        )
        XCTAssertEqual(turnStart.method, "turn/start")
        let turnParams = try XCTUnwrap(turnStart.params?.objectValue)
        XCTAssertEqual(turnParams["cwd"]?.stringValue, project.path)
        XCTAssertNil(turnParams["model"]?.stringValue)
        XCTAssertEqual(turnParams["effort"]?.stringValue, "xhigh")
        XCTAssertEqual(turnParams["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(turnParams["approvalsReviewer"]?.stringValue, "user")
        XCTAssertEqual(turnParams["clientUserMessageId"]?.stringValue, "client_safe")
        let sandbox = try XCTUnwrap(turnParams["sandboxPolicy"]?.objectValue)
        XCTAssertEqual(sandbox["type"]?.stringValue, "dangerFullAccess")
        XCTAssertEqual(sandbox["networkAccess"]?.boolValue, false)
        XCTAssertNil(sandbox["writableRoots"])

        XCTAssertThrowsError(try builder.threadStart(cwd: "/tmp/not-allowlisted"))
        XCTAssertThrowsError(try builder.turnStart(threadID: "thr_safe", cwd: "/tmp/not-allowlisted", prompt: "hi"))
        XCTAssertThrowsError(try builder.validateRemoteSafeParams(
            .object(["cwd": .string(project.path), "approvalPolicy": .string("never")]),
            projectPath: project.path
        ))
        XCTAssertNoThrow(try builder.validateRemoteSafeParams(
            .object(["cwd": .string(project.path), "sandbox": .string("danger-full-access")]),
            projectPath: project.path
        ))
        XCTAssertEqual(builder.accountRateLimitsRead().method, "account/rateLimits/read")
    }

    func testCodexUsageDisplaySummaryFormatsRateLimit() throws {
        XCTAssertEqual(RateLimitSummary(remainingRequests: 18).compactText, "剩余 18 次")
        XCTAssertEqual(RateLimitSummary(primaryUsedPercent: 72).compactText, "已用 72%")
        XCTAssertEqual(RateLimitSummary(primaryUsedPercent: 100).compactText, "额度已用尽")
        XCTAssertNil(CodexUsageDisplaySummary.make(rateLimit: nil))
        XCTAssertNil(CodexUsageDisplaySummary.make(rateLimit: RateLimitSummary(limitID: "codex")))

        let now = Date(timeIntervalSince1970: 1_780_490_700)
        let resetEpoch: Int64 = 1_780_494_300
        let summary = RateLimitSummary(
            limitName: "Codex",
            primaryUsedPercent: 60,
            secondaryUsedPercent: 42,
            primaryResetsAt: resetEpoch
        )
        let display = try XCTUnwrap(CodexUsageDisplaySummary.make(rateLimit: summary, now: now))
        XCTAssertEqual(display.title, "Codex 使用量")
        XCTAssertEqual(display.primaryText, "已用 60%")
        XCTAssertEqual(display.secondaryText.hasPrefix("预计 "), true)
        XCTAssertEqual(display.secondaryText.hasSuffix(" 重置"), true)
        XCTAssertEqual(display.progress ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertEqual(display.resetDate, Date(timeIntervalSince1970: TimeInterval(resetEpoch)))
        XCTAssertFalse(display.isNearLimit)
        XCTAssertFalse(display.isExhausted)

        let windowsDisplay = CodexUsageWindowsDisplay.make(rateLimit: summary, now: now)
        let fiveHourWindow = try XCTUnwrap(windowsDisplay.windows.first { $0.kind == .fiveHour })
        let sevenDayWindow = try XCTUnwrap(windowsDisplay.windows.first { $0.kind == .sevenDay })
        XCTAssertEqual(windowsDisplay.displayName, "Codex")
        XCTAssertEqual(windowsDisplay.creditText, "暂无余额信息")
        XCTAssertTrue(windowsDisplay.hasLiveData)
        XCTAssertEqual(fiveHourWindow.primaryText, "已用 60%")
        XCTAssertEqual(fiveHourWindow.progress ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertEqual(fiveHourWindow.resetDate, Date(timeIntervalSince1970: TimeInterval(resetEpoch)))
        XCTAssertEqual(fiveHourWindow.resetText.hasSuffix(" 重置"), true)
        XCTAssertEqual(sevenDayWindow.primaryText, "已用 42%")
        XCTAssertNil(sevenDayWindow.resetDate)
        XCTAssertEqual(sevenDayWindow.resetText, "暂无重置时间")

        let pendingWindowsDisplay = CodexUsageWindowsDisplay.make(rateLimit: nil, now: now)
        XCTAssertFalse(pendingWindowsDisplay.hasLiveData)
        XCTAssertEqual(try XCTUnwrap(pendingWindowsDisplay.windows.first { $0.kind == .fiveHour }).primaryText, "等待刷新")
        XCTAssertEqual(try XCTUnwrap(pendingWindowsDisplay.windows.first { $0.kind == .sevenDay }).primaryText, "等待刷新")

        let eightyPercent = try XCTUnwrap(CodexUsageDisplaySummary.make(rateLimit: RateLimitSummary(primaryUsedPercent: 80), now: now))
        XCTAssertFalse(eightyPercent.isNearLimit)
        let almostNearLimit = try XCTUnwrap(CodexUsageDisplaySummary.make(rateLimit: RateLimitSummary(primaryUsedPercent: 84), now: now))
        XCTAssertFalse(almostNearLimit.isNearLimit)
        let nearLimit = try XCTUnwrap(CodexUsageDisplaySummary.make(rateLimit: RateLimitSummary(primaryUsedPercent: 85), now: now))
        XCTAssertTrue(nearLimit.isNearLimit)

        let exhaustedLimit = RateLimitSummary(limitName: "Codex", primaryUsedPercent: 100, primaryResetsAt: resetEpoch)
        let exhaustedDisplay = try XCTUnwrap(CodexUsageDisplaySummary.make(rateLimit: exhaustedLimit, now: now))
        XCTAssertTrue(exhaustedDisplay.isExhausted)
        let exhaustedNotice = try XCTUnwrap(CodexQuotaNotice.make(rateLimit: exhaustedLimit, errorMessage: nil, now: now))
        XCTAssertTrue(exhaustedNotice.blocksSending)
        XCTAssertEqual(exhaustedNotice.title, "Codex 消息额度已用尽")

        let secondaryResetEpoch: Int64 = 1_780_497_900
        let secondaryDriven = try XCTUnwrap(CodexUsageDisplaySummary.make(
            rateLimit: RateLimitSummary(
                primaryUsedPercent: 40,
                secondaryUsedPercent: 90,
                primaryResetsAt: resetEpoch,
                secondaryResetsAt: secondaryResetEpoch
            ),
            now: now
        ))
        XCTAssertEqual(secondaryDriven.primaryText, "已用 90%")
        XCTAssertEqual(secondaryDriven.resetDate, Date(timeIntervalSince1970: TimeInterval(secondaryResetEpoch)))

        let secondaryWindows = CodexUsageWindowsDisplay.make(
            rateLimit: RateLimitSummary(
                reachedType: "secondary",
                primaryUsedPercent: 40,
                secondaryUsedPercent: 100,
                secondaryResetsAt: secondaryResetEpoch
            ),
            now: now
        )
        XCTAssertFalse(try XCTUnwrap(secondaryWindows.windows.first { $0.kind == .fiveHour }).isExhausted)
        XCTAssertTrue(try XCTUnwrap(secondaryWindows.windows.first { $0.kind == .sevenDay }).isExhausted)
    }

    func testDirectRuntimeAttachesUsageDisplayForAvailableRateLimit() async throws {
        let project = AgentProject(id: "proj_rate_limit_available", name: "Rate Limit", path: "/tmp/rate-limit-available")
        let transport = FakeCodexAppServerTransport()
        let allowedMethods = [
            "initialize",
            "initialized",
            "thread/list",
            "thread/start",
            "thread/read",
            "turn/start",
            "turn/interrupt",
            "account/rateLimits/read"
        ]
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project, allowedMethods: allowedMethods) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let threadList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: threadList.id, result: #"{"data":[{"id":"thr_rate_limit_available","sessionId":"thr_rate_limit_available","preview":"quota","ephemeral":false,"modelProvider":"openai","createdAt":1780490700,"updatedAt":1780490701,"status":{"type":"idle"},"path":null,"cwd":"/tmp/rate-limit-available","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"额度展示","turns":[]}],"nextCursor":null}"#)

        let page = try await pageTask.value
        let initialSession = try XCTUnwrap(page.sessions.first)
        XCTAssertNil(initialSession.rateLimit)

        let rateLimit = try await waitForFakeAppServerRequest(transport, method: "account/rateLimits/read")
        transportResponse(transport, id: rateLimit.id, result: #"{"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":"Codex","primary":{"usedPercent":60,"resetsAt":1780494300},"secondary":{"usedPercent":42},"credits":{"hasCredits":false,"unlimited":false}}}}"#)

        let messagesBeforeSecondPage = await transport.sentMessages().count
        let secondPageTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let secondThreadList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: messagesBeforeSecondPage)
        transportResponse(transport, id: secondThreadList.id, result: #"{"data":[{"id":"thr_rate_limit_available","sessionId":"thr_rate_limit_available","preview":"quota","ephemeral":false,"modelProvider":"openai","createdAt":1780490700,"updatedAt":1780490701,"status":{"type":"idle"},"path":null,"cwd":"/tmp/rate-limit-available","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"额度展示","turns":[]}],"nextCursor":null}"#)

        let refreshedPage = try await secondPageTask.value
        let session = try XCTUnwrap(refreshedPage.sessions.first)
        XCTAssertEqual(session.rateLimit?.compactText, "已用 60%")
        let display = try XCTUnwrap(CodexUsageDisplaySummary.make(rateLimit: session.rateLimit, now: Date(timeIntervalSince1970: 1_780_490_700)))
        XCTAssertEqual(display.primaryText, "已用 60%")
        XCTAssertEqual(display.progress ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertFalse(display.isExhausted)
    }

    func testDirectRuntimeAttachesAccountRateLimitToSessionRows() async throws {
        let project = AgentProject(id: "proj_rate_limit", name: "Rate Limit", path: "/tmp/rate-limit")
        let transport = FakeCodexAppServerTransport()
        let allowedMethods = [
            "initialize",
            "initialized",
            "thread/list",
            "thread/start",
            "thread/read",
            "turn/start",
            "turn/interrupt",
            "account/rateLimits/read"
        ]
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project, allowedMethods: allowedMethods) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)

        let threadList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: threadList.id, result: #"{"data":[{"id":"thr_rate_limit","sessionId":"thr_rate_limit","preview":"quota","ephemeral":false,"modelProvider":"openai","createdAt":1780490700,"updatedAt":1780490701,"status":{"type":"idle"},"path":null,"cwd":"/tmp/rate-limit","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"额度提示","turns":[]}],"nextCursor":null}"#)

        let initialPage = try await pageTask.value
        XCTAssertNil(try XCTUnwrap(initialPage.sessions.first).rateLimit)

        let rateLimit = try await waitForFakeAppServerRequest(transport, method: "account/rateLimits/read")
        transportResponse(transport, id: rateLimit.id, result: #"{"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":"Codex","rateLimitReachedType":"primary","primary":{"usedPercent":100,"resetsAt":1780494300},"credits":{"hasCredits":false,"unlimited":false}}}}"#)

        let messagesBeforeSecondPage = await transport.sentMessages().count
        let secondPageTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let secondThreadList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: messagesBeforeSecondPage)
        transportResponse(transport, id: secondThreadList.id, result: #"{"data":[{"id":"thr_rate_limit","sessionId":"thr_rate_limit","preview":"quota","ephemeral":false,"modelProvider":"openai","createdAt":1780490700,"updatedAt":1780490701,"status":{"type":"idle"},"path":null,"cwd":"/tmp/rate-limit","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"额度提示","turns":[]}],"nextCursor":null}"#)

        let page = try await secondPageTask.value
        let session = try XCTUnwrap(page.sessions.first)
        XCTAssertEqual(session.rateLimit?.limitID, "codex")
        XCTAssertEqual(session.rateLimit?.limitName, "Codex")
        XCTAssertEqual(session.rateLimit?.primaryUsedPercent, 100)
        XCTAssertEqual(session.rateLimit?.primaryResetsAt, 1_780_494_300)
        XCTAssertTrue(try XCTUnwrap(session.rateLimit?.isExhausted))
        XCTAssertEqual(session.rateLimit?.compactText, "额度已用尽")
    }

    func testQuotaNoticeRecognizesQuotaButIgnoresSkillBudgetWarning() {
        XCTAssertTrue(CodexQuotaNotice.isQuotaError("Your Codex message limit has been exhausted."))
        XCTAssertTrue(CodexQuotaNotice.isQuotaError("HTTP 429: rate limit exceeded"))
        XCTAssertFalse(CodexQuotaNotice.isQuotaError("Skill descriptions were shortened to fit the 2% skills context budget."))
    }
}

// 冷启动重试用的客户端：前 N 次 projects() 抛错模拟隧道未就绪，之后成功返回。
private final class FlakyBootstrapClient: SessionStoreAPIClient {
    private let failuresBeforeSuccess: Int
    private let sessionFailuresBeforeSuccess: Int
    private let projectsResult: [AgentProject]
    private let sessionsResult: [AgentSession]
    private(set) var projectsCallCount = 0
    private(set) var sessionsCallCount = 0

    init(
        failuresBeforeSuccess: Int,
        sessionFailuresBeforeSuccess: Int = 0,
        projects: [AgentProject],
        sessions: [AgentSession]
    ) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.sessionFailuresBeforeSuccess = sessionFailuresBeforeSuccess
        self.projectsResult = projects
        self.sessionsResult = sessions
    }

    func projects() async throws -> [AgentProject] {
        projectsCallCount += 1
        if projectsCallCount <= failuresBeforeSuccess {
            throw AgentAPIError.server(status: 503, message: "tunnel not ready")
        }
        return projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        sessionsCallCount += 1
        if sessionsCallCount <= sessionFailuresBeforeSuccess {
            // 模拟 agentd HTTP 已就绪、但 app-server gateway 上游还没接受连接的冷启动窗口。
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
        }
        return sessionsResult
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        []
    }
}

private enum MockError: Error {
    case unimplemented
    case timeout
}

private enum FakeCodexAppServerTransportError: LocalizedError {
    case receiveFailed

    var errorDescription: String? {
        "fake app-server receive failed"
    }
}

private func occurrenceCount(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

private final class FakeCodexAppServerTransport: CodexAppServerTransport {
    private let sentStore = FakeCodexAppServerSentStore()
    private var receiveContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private var receiveIterator: AsyncThrowingStream<String, Error>.Iterator

    init() {
        var continuation: AsyncThrowingStream<String, Error>.Continuation?
        let stream = AsyncThrowingStream<String, Error> {
            continuation = $0
        }
        self.receiveContinuation = continuation
        self.receiveIterator = stream.makeAsyncIterator()
    }

    func connect(url: URL, token: String) async throws {}

    func send(_ text: String) async throws {
        await sentStore.append(text)
    }

    func receive() async throws -> String? {
        try await receiveIterator.next()
    }

    func close() async {
        receiveContinuation?.finish()
    }

    func enqueue(_ text: String) {
        receiveContinuation?.yield(text)
    }

    func failReceive(_ error: Error = FakeCodexAppServerTransportError.receiveFailed) {
        receiveContinuation?.finish(throwing: error)
    }

    func sentMessages() async -> [String] {
        await sentStore.snapshot()
    }
}

private final class FakeCodexAppServerTransportPool {
    private let lock = NSLock()
    private var transports: [FakeCodexAppServerTransport] = []

    func make() -> CodexAppServerTransport {
        let transport = FakeCodexAppServerTransport()
        lock.lock()
        transports.append(transport)
        lock.unlock()
        return transport
    }

    func transport(at index: Int) -> FakeCodexAppServerTransport? {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard transports.indices.contains(index) else {
            return nil
        }
        return transports[index]
    }
}

private final class SequencedDirectConfigProvider {
    private let lock = NSLock()
    private let configs: [CodexAppServerConfigResponse]
    private var index = 0

    init(_ configs: [CodexAppServerConfigResponse]) {
        self.configs = configs
    }

    var callCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return index
    }

    func next() async throws -> CodexAppServerConfigResponse {
        takeNext()
    }

    private func takeNext() -> CodexAppServerConfigResponse {
        lock.lock()
        defer {
            lock.unlock()
        }
        let config = configs[min(index, max(0, configs.count - 1))]
        index += 1
        return config
    }
}

private actor FakeCodexAppServerSentStore {
    private var messages: [String] = []

    func append(_ text: String) {
        messages.append(text)
    }

    func snapshot() -> [String] {
        messages
    }
}

private func waitForFakeAppServerTransport(
    in pool: FakeCodexAppServerTransportPool,
    index: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> FakeCodexAppServerTransport {
    for _ in 0..<200 {
        if let transport = pool.transport(at: index) {
            return transport
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for app-server transport \(index)", file: file, line: line)
    throw MockError.unimplemented
}

private func waitForFakeAppServerMessages(
    _ transport: FakeCodexAppServerTransport,
    count: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> [String] {
    for _ in 0..<200 {
        let messages = await transport.sentMessages()
        if messages.count >= count {
            return messages
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for \(count) app-server messages", file: file, line: line)
    return await transport.sentMessages()
}

private func waitForFakeAppServerRequest(
    _ transport: FakeCodexAppServerTransport,
    method: String,
    after startIndex: Int = 0,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> CodexAppServerRequest {
    for _ in 0..<200 {
        let messages = await transport.sentMessages()
        if startIndex < messages.count {
            for text in messages[startIndex...] {
                guard let request = try? decodeAppServerRequest(text) else {
                    continue
                }
                if request.method == method {
                    return request
                }
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for app-server request \(method)", file: file, line: line)
    throw MockError.unimplemented
}

private func assertInitializeEnablesExperimentalAPI(
    _ initialize: CodexAppServerRequest,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(initialize.method, "initialize", file: file, line: line)
    let params = initialize.params?.objectValue
    let capabilities = params?["capabilities"]?.objectValue
    // collaborationMode 是 app-server 的 experimental turn/start 字段；
    // 初始化时必须声明 experimentalApi，否则计划模式会被真实服务端拒绝或降级。
    XCTAssertEqual(capabilities?["experimentalApi"]?.boolValue, true, file: file, line: line)
    XCTAssertEqual(capabilities?["requestAttestation"]?.boolValue, false, file: file, line: line)
}

private func waitForFakeAppServerResponse(
    _ transport: FakeCodexAppServerTransport,
    id: CodexAppServerRequestID,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> CodexAppServerResponse {
    for _ in 0..<200 {
        let messages = await transport.sentMessages()
        for text in messages {
            guard
                let response = try? AgentAPIClient.decoder.decode(
                    CodexAppServerResponse.self,
                    from: Data(text.utf8)
                ),
                response.id == id,
                response.result != nil || response.error != nil
            else {
                continue
            }
            return response
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for app-server response \(id)", file: file, line: line)
    throw MockError.unimplemented
}

private func connectFakeAppServer(
    _ connection: CodexAppServerConnection,
    transport: FakeCodexAppServerTransport
) async throws {
    let connectTask = Task {
        try await connection.connect(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:7777/api/app-server/ws")), token: "test-token")
    }
    let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
    let initialize = try decodeAppServerRequest(initializeMessages[0])
    assertInitializeEnablesExperimentalAPI(initialize)
    transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)
    try await connectTask.value

    let connectedMessages = try await waitForFakeAppServerMessages(transport, count: 2)
    let initialized = try AgentAPIClient.decoder.decode(
        CodexAppServerNotification.self,
        from: Data(connectedMessages[1].utf8)
    )
    XCTAssertEqual(initialized.method, "initialized")
}

private func waitForRuntimeConnectionToBecomeUnavailable(
    _ runtime: CodexAppServerSessionRuntime,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    for _ in 0..<200 {
        let ready = await runtime.hasReadyConnectionForTesting()
        if !ready {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for app-server runtime connection to become unavailable", file: file, line: line)
}

private func makeDirectAppServerConfig(
    project: AgentProject,
    gatewayAvailable: Bool = true,
    allowedMethods: [String]? = nil,
    channels: [CodexAppServerChannelMetadata] = []
) -> CodexAppServerConfigResponse {
    let defaultAllowedMethods = ["initialize", "initialized", "thread/list", "thread/start", "thread/read", "turn/start", "turn/interrupt"]
    return CodexAppServerConfigResponse(
        gatewayWSURL: gatewayAvailable ? "ws://127.0.0.1:7777/api/app-server/ws" : "",
        runtime: CodexAppServerRuntimeMetadata(
            type: "codex_app_server",
            transport: "ws",
            managed: true,
            gatewayAvailable: gatewayAvailable,
        upstreamConfigured: gatewayAvailable,
        running: gatewayAvailable,
        initialized: false,
        pendingRequests: 0
        ),
        channels: channels,
        projects: [project],
        policy: CodexAppServerPolicyMetadata(
            allowedMethods: allowedMethods ?? defaultAllowedMethods,
            projectsSource: "agentd_allowlist"
        )
    )
}

private func makeClaudeChannelMetadata() -> CodexAppServerChannelMetadata {
    CodexAppServerChannelMetadata(
        id: "claude",
        runtimeID: "claude",
        title: "Claude Code",
        provider: "anthropic",
        type: "claude_code_bridge",
        protocolName: "app_server_jsonrpc_stdio_v1",
        gatewayWSURL: "ws://127.0.0.1:7777/api/app-server/ws?runtime=claude",
        gatewayAvailable: true,
        managed: false,
        experimental: true,
        lifecycle: "per_connection",
        bridge: nil,
        methods: ["initialize", "initialized", "thread/list", "thread/start", "turn/start", "model/list"],
        capabilities: ["history": true, "streaming": true]
    )
}

private func appServerThreadListResult(_ rows: [String], nextCursor: String?) -> String {
    let encodedCursor = nextCursor.map { #","nextCursor":"\#($0)""# } ?? #","nextCursor":null"#
    return #"{"data":[\#(rows.joined(separator: ","))]\#(encodedCursor)}"#
}

private func appServerThreadJSON(id: String, cwd: String, source: String, updatedAt: Int) -> String {
    """
    {"id":"\(id)","sessionId":"\(id)","preview":"\(id)","ephemeral":false,"modelProvider":"openai","createdAt":\(updatedAt - 10),"updatedAt":\(updatedAt),"status":{"type":"idle"},"path":null,"cwd":"\(cwd)","cliVersion":"0.0.0","source":"\(source)","threadSource":"user","name":"\(id)","turns":[]}
    """
}

private func decodeAppServerRequest(_ text: String) throws -> CodexAppServerRequest {
    try AgentAPIClient.decoder.decode(CodexAppServerRequest.self, from: Data(text.utf8))
}

private func decodeAppServerNotification(_ text: String) throws -> CodexAppServerNotification {
    try AgentAPIClient.decoder.decode(CodexAppServerNotification.self, from: Data(text.utf8))
}

private func loadDirectAppServerEventStreamFixture(
    named fixtureName: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> [AgentEvent] {
    // 测试 target 目前没有 Copy Bundle Resources；这里用源码文件路径定位 fixture，
    // 保持本次改动只触碰测试代码和测试数据，不要求主线程立即重新生成 Xcode 工程。
    let testFileURL = URL(fileURLWithPath: String(describing: file))
    let fixtureURL = testFileURL
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(fixtureName)
    let content = try String(contentsOf: fixtureURL, encoding: .utf8)
    var projector = CodexAppServerEventProjector()
    var events: [AgentEvent] = []

    for (index, rawLine) in content.split(whereSeparator: \.isNewline).enumerated() {
        let lineText = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lineText.isEmpty else {
            continue
        }
        let message = try AgentAPIClient.decoder.decode(CodexAppServerMessage.self, from: Data(lineText.utf8))
        let event: AgentEvent?
        switch message {
        case .notification(let notification):
            event = projector.project(notification)
        case .serverRequest(let request):
            event = projector.project(request)
        case .response:
            event = nil
        }
        guard let event else {
            XCTFail("fixture 第 \(index + 1) 行无法投影为 AgentEvent: \(lineText)", file: file, line: line)
            throw MockError.unimplemented
        }
        events.append(event)
    }

    return events
}

private func jsonFragment(for id: CodexAppServerRequestID) throws -> String {
    let data = try JSONEncoder().encode(id)
    return String(decoding: data, as: UTF8.self)
}

private func transportResponse(_ transport: FakeCodexAppServerTransport, id: CodexAppServerRequestID, result: String) {
    let encodedID = (try? jsonFragment(for: id)) ?? "null"
    transport.enqueue(#"{"id":\#(encodedID),"result":\#(result)}"#)
}

private func transportErrorResponse(_ transport: FakeCodexAppServerTransport, id: CodexAppServerRequestID, code: Int, message: String) {
    let encodedID = (try? jsonFragment(for: id)) ?? "null"
    let encodedMessage = (try? String(decoding: JSONEncoder().encode(message), as: UTF8.self)) ?? #""app-server error""#
    transport.enqueue(#"{"id":\#(encodedID),"error":{"code":\#(code),"message":\#(encodedMessage)}}"#)
}

private func historyPolicyError(reason: String, retryAfterMs: Int? = nil) -> Error {
    var data: [String: CodexAppServerJSONValue] = [
        "reason": .string(reason),
        "method": .string("thread/turns/list"),
        "threadId": .string("codex_history_policy_test"),
        "itemsView": .string(reason == "history_response_too_large" ? "full" : "summary")
    ]
    if let retryAfterMs {
        data["retryAfterMs"] = .int(Int64(retryAfterMs))
        data["retryAfterSeconds"] = .int(Int64(max(1, (retryAfterMs + 999) / 1_000)))
    }
    let message: String
    switch reason {
    case "history_response_too_large":
        message = "thread/turns/list history response 过大，gateway 已阻断；请降低 limit/itemsView 或改用分页读取"
    default:
        message = "thread/turns/list 同一 thread/method 正在临时限流，请稍后重试或降低 limit/itemsView"
    }
    return CodexAppServerConnectionError.appServer(CodexAppServerError(
        code: -32080,
        message: message,
        data: .object(data)
    ))
}

private func makeProject(id: String) -> AgentProject {
    AgentProject(id: id, name: id, path: "/tmp/\(id)")
}

private func makeChildWorkspace(id: String, name: String, root: AgentProject) -> AgentWorkspace {
    AgentWorkspace(
        id: id,
        name: name,
        path: "\(root.path)/\(name)",
        rootProjectID: root.id,
        rootProjectName: root.name,
        rootProjectPath: root.path,
        lastOpenedAt: Date(timeIntervalSince1970: 10)
    )
}

private func makeRecentWorkspaceStore(workspaces: [AgentWorkspace], endpoint: String) -> RecentWorkspaceStore {
    let suiteName = "RecentWorkspaceStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    let store = RecentWorkspaceStore(defaults: defaults)
    store.save(workspaces, endpoint: endpoint)
    return store
}

private func makeSessionListPreferenceStore() -> SessionListPreferenceStore {
    let suiteName = "SessionListPreferenceStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return SessionListPreferenceStore(defaults: defaults)
}

private func makeSessionReminderStore() -> SessionReminderStore {
    let suiteName = "SessionReminderStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return SessionReminderStore(defaults: defaults)
}

private func makeCreateSessionResponse(session: AgentSession, firstMessageJSON: String? = nil) throws -> CreateSessionResponse {
    let firstMessageField = firstMessageJSON.map { ",\n      \($0)" } ?? ""
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
      "ws_url": "/api/app-server/ws?thread_id=\(session.id)"\(firstMessageField)
    }
    """
    return try AgentAPIClient.decoder.decode(CreateSessionResponse.self, from: Data(json.utf8))
}

private func makeSessionResponse(session: AgentSession, recentOutput: String?, lastSeq: EventSequence? = nil) throws -> SessionResponse {
    let escapedRecentOutput: String
    if let recentOutput {
        let data = try JSONEncoder().encode(recentOutput)
        escapedRecentOutput = String(decoding: data, as: UTF8.self)
    } else {
        escapedRecentOutput = "null"
    }
    let encodedLastSeq = lastSeq.map(String.init) ?? "null"
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
      "recent_output": \(escapedRecentOutput),
      "last_seq": \(encodedLastSeq)
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
	runtimeProvider: String? = nil,
	resumeID: String? = nil,
    preview: String? = nil,
    activeTurnID: TurnID? = nil,
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
	runtimeProvider: runtimeProvider,
	resumeID: resumeID,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: updatedAt,
        preview: preview,
        activeTurnID: activeTurnID
    )
}
