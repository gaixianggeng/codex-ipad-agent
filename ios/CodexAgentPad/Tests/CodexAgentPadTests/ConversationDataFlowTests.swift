import XCTest
import Combine
@testable import CodexAgentPad

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
        XCTAssertEqual(group.title, "已处理 9s")
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
        XCTAssertEqual(group.title, "已处理 4s")
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
                createdAt: Date(timeIntervalSince1970: 4_500),
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

    func testStructuredHistoryProcessMessagesCollapseBeforeFinalAssistant() throws {
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
                kind: .reasoningSummary,
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

        XCTAssertEqual(items.count, 3)
        guard case .processed(let group) = items[1] else {
            return XCTFail("history 过程消息应该折叠到最终 assistant 前")
        }
        XCTAssertEqual(group.messages.map(\.content), ["我先调用一个子 agent。", "让子 agent 生成一个短笑话。"])
        XCTAssertEqual(group.title, "已处理 34s")
        guard case .message(let final) = items[2] else {
            return XCTFail("最终 assistant 应保持独立展开")
        }
        XCTAssertEqual(final.role, .assistant)
        XCTAssertEqual(final.content, "程序员相亲，对方问：你会浪漫吗？")
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

        store.setHistory([
            CodexHistoryMessage(role: "assistant", content: "现有回答", createdAt: nil)
        ], sessionID: sessionID)
        guard let existing = store.messages(for: sessionID).first else {
            return XCTFail("首屏历史应生成一条消息")
        }

        store.setHistory([
            CodexHistoryMessage(role: "user", content: "更早问题", createdAt: nil),
            CodexHistoryMessage(role: "assistant", content: "现有回答", createdAt: nil)
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        let reused = messages.first { $0.content == "现有回答" }
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(reused?.id, existing.id)
        XCTAssertEqual(reused?.createdAt, existing.createdAt)
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
                "send_status": "confirmed"
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
        XCTAssertEqual(response.nextCursor, "next")
        XCTAssertEqual(response.previousCursor, "prev")
        XCTAssertEqual(response.hasMoreBefore, true)
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
          "project": "Codex iPad Agent",
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
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(sockets.first?.connectedSessionIDs.first, running.id)
        try await waitForWebSocketStatus(.connecting, store: store)
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
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [history]) }
        )
        store.selectedProjectID = project.id
        store.selectedSessionID = history.id
        await store.toggleProjectExpansion(project)
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
        XCTAssertEqual(snapshot.actionTitle, "展开显示")

        await store.toggleSessionListExpansion(projectID: project.id)
        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).count, 5)
        XCTAssertEqual(store.hiddenSessionCount(forProjectID: project.id), 2)
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
        XCTAssertEqual(snapshot.actionTitle, "展开显示")

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
        XCTAssertEqual(snapshot.actionTitle, "展开显示")

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

        await store.selectSession(history)

        XCTAssertEqual(client.requestedMessageCursors, [nil])

        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:100", role: "assistant", content: "首屏历史", createdAt: Date(timeIntervalSince1970: 10))
                ]
            )
        )
        await firstSelectTask.value

        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["首屏历史"])
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

    func testStaleHistoryFirstPageResponseDoesNotOverwriteNewerRefresh() async {
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
        await client.waitForHistoryRequestCount(2)

        client.resolveHistoryRequest(
            at: 1,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:200", role: "assistant", content: "新历史", createdAt: Date(timeIntervalSince1970: 20))
                ],
                previousCursor: "fresh_cursor",
                hasMoreBefore: true
            )
        )
        await refreshTask.value
        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["新历史"])

        let secondRefreshTask = Task { await store.refreshCurrentContext() }
        await client.waitForHistoryRequestCount(3)

        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:100", role: "assistant", content: "旧历史", createdAt: Date(timeIntervalSince1970: 10))
                ],
                previousCursor: "stale_cursor",
                hasMoreBefore: true
            )
        )
        await selectTask.value

        // 旧的 before=nil 响应晚到后必须丢弃，不能把较新的手动刷新结果和 cursor 覆盖掉。
        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["新历史"])
        XCTAssertTrue(store.canLoadEarlierHistory(sessionID: history.id))

        client.resolveHistoryRequest(
            at: 2,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:300", role: "assistant", content: "最新历史", createdAt: Date(timeIntervalSince1970: 30))
                ],
                previousCursor: "latest_cursor",
                hasMoreBefore: true
            )
        )
        await secondRefreshTask.value

        XCTAssertEqual(client.requestedMessageCursors, [nil, nil, nil])
        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["新历史", "最新历史"])
        XCTAssertTrue(store.canLoadEarlierHistory(sessionID: history.id))
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
        XCTAssertEqual(sockets[0].sentInputs.count, 1)
        XCTAssertEqual(sockets[0].sentInputs.first?.text, "请重试\r")
        XCTAssertEqual(sockets[0].sentInputs.first?.clientMessageID, "client-retry")
        let messages = conversationStore.messages(for: running.id)
        let retriedMessages = messages.filter { $0.clientMessageID == "client-retry" }
        XCTAssertEqual(retriedMessages.count, 1)
        XCTAssertEqual(retriedMessages.first?.sendStatus, .sent)
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
        await store.selectSession(waiting)
        XCTAssertEqual(sockets.count, 1)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        store.decideApproval(approval, accept: true)

        XCTAssertEqual(sockets[0].sentApprovals.count, 1)
        XCTAssertEqual(sockets[0].sentApprovals.first?.approvalID, "approval-1")
        XCTAssertEqual(sockets[0].sentApprovals.first?.decision, "accept")
        XCTAssertEqual(store.selectedSession?.status, "running")
        XCTAssertEqual(store.selectedSession?.pendingApproval, nil)
        XCTAssertTrue(conversationStore.messages(for: waiting.id).contains { message in
            message.kind == .approval && message.content.contains("审批已批准")
        })
    }

    func testApprovalRequestUpdatesSelectedSessionPendingApproval() async throws {
        let project = makeProject(id: "proj_approval_event")
        let running = makeSession(id: "sess_approval_event", projectID: project.id, title: "运行中", status: "running", source: "codex")
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

        store.decideApproval(try XCTUnwrap(store.selectedSession?.pendingApproval), accept: true)

        XCTAssertEqual(sockets[0].sentApprovals.first?.approvalID, "cmd-approval")
        XCTAssertNil(store.selectedSession?.pendingApproval)
        XCTAssertEqual(store.selectedSession?.status, "running")
        XCTAssertTrue(conversationStore.messages(for: running.id).contains { message in
            message.kind == .approval && message.content.contains("审批已批准：运行 curl")
        })
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
        XCTAssertEqual(pendingApproval.title, "Codex 请求执行命令：go test ./ios/CodexAgentPad")
        XCTAssertTrue(conversationStore.messages(for: sessionID).contains { $0.kind == .approval && $0.content.contains("等待审批") })

        store.decideApproval(pendingApproval, accept: true)

        XCTAssertEqual(sockets[0].sentApprovals.first?.approvalID, "cmd_fixture_approval")
        XCTAssertEqual(sockets[0].sentApprovals.first?.decision, "accept")
        XCTAssertNil(store.selectedSession?.pendingApproval)

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

    func testApprovalDecisionMarksConversationRecordDeclined() async throws {
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
        await store.selectSession(waiting)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        store.decideApproval(approval, accept: false)

        XCTAssertEqual(sockets[0].sentApprovals.first?.decision, "decline")
        XCTAssertEqual(conversationStore.messages(for: waiting.id).filter { $0.kind == .approval }.last?.content, "审批已拒绝：运行危险命令")
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
}

private final class MockWebSocketClient: SessionWebSocketClient {
    var onEvent: ((AgentEvent) -> Void)?
    var onStatus: ((WebSocketStatus) -> Void)?
    var onSendFailure: ((ClientMessageID?, String) -> Void)?

    private(set) var connectedSessionIDs: [SessionID] = []
    private(set) var sentInputs: [(text: String, clientMessageID: ClientMessageID?)] = []
    private(set) var sentApprovals: [(approvalID: String, decision: String, message: String?)] = []
    private(set) var disconnectCallCount = 0

    func connect(sessionID: SessionID) {
        connectedSessionIDs.append(sessionID)
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

    func sendCtrlC() -> Bool {
        true
    }

    func sendApprovalDecision(approvalID: String, decision: String, message: String?) -> Bool {
        sentApprovals.append((approvalID, decision, message))
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

private final class MockSessionStoreClient: SessionStoreAPIClient {
    let projectsResult: [AgentProject]
    let sessionsResult: [AgentSession]
    let projectSessions: [String: [AgentSession]]
    let projectPages: [String: SessionsPage]
    let cursorPages: [String: SessionsPage]
    let createSessionResponse: CreateSessionResponse?
    let sessionResponses: [String: SessionResponse]
    let messagesResult: [CodexHistoryMessage]
    let historyPages: [String: HistoryMessagesPage]
    let historyCursorPages: [String: HistoryMessagesPage]
    let workspaceSessionsError: [String: Error]
    let resolveResults: [String: Result<AgentWorkspace, Error>]
    let messagesError: Error?
    var requestedProjectIDs: [String?] = []
    var requestedWorkspaceIDs: [String] = []
    var requestedResolvePaths: [String] = []
    var requestedSessionIDs: [String] = []
    var requestedSessionAfterSeqs: [EventSequence?] = []
    var requestedMessageSessionIDs: [String] = []
    var requestedMessageCursors: [String?] = []
    var createPayloads: [CreateSessionRequest] = []

    init(
        projects: [AgentProject],
        sessions: [AgentSession],
        projectSessions: [String: [AgentSession]] = [:],
        projectPages: [String: SessionsPage] = [:],
        cursorPages: [String: SessionsPage] = [:],
        createSessionResponse: CreateSessionResponse? = nil,
        sessionResponses: [String: SessionResponse] = [:],
        messagesResult: [CodexHistoryMessage]? = nil,
        historyPages: [String: HistoryMessagesPage] = [:],
        historyCursorPages: [String: HistoryMessagesPage] = [:],
        workspaceSessionsError: [String: Error] = [:],
        resolveResults: [String: Result<AgentWorkspace, Error>] = [:],
        messagesError: Error? = nil
    ) {
        self.projectsResult = projects
        self.sessionsResult = sessions
        self.projectSessions = projectSessions
        self.projectPages = projectPages
        self.cursorPages = cursorPages
        self.createSessionResponse = createSessionResponse
        self.sessionResponses = sessionResponses
        self.messagesResult = messagesResult ?? [
            CodexHistoryMessage(role: "user", content: "历史问题", createdAt: Date(timeIntervalSince1970: 1)),
            CodexHistoryMessage(role: "assistant", content: "历史回答", createdAt: Date(timeIntervalSince1970: 2))
        ]
        self.historyPages = historyPages
        self.historyCursorPages = historyCursorPages
        self.workspaceSessionsError = workspaceSessionsError
        self.resolveResults = resolveResults
        self.messagesError = messagesError
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
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

    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?) async throws -> SessionsPage {
        requestedWorkspaceIDs.append(workspace.id)
        if let error = workspaceSessionsError[workspace.id] {
            throw error
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
    var historyPages: [SessionID: HistoryMessagesPage]
    var historyCursorPages: [String: HistoryMessagesPage]
    var requestedMessageCursors: [String?] = []

    init(
        projects: [AgentProject],
        page: SessionsPage,
        historyPages: [SessionID: HistoryMessagesPage] = [:],
        historyCursorPages: [String: HistoryMessagesPage] = [:]
    ) {
        self.projectsResult = projects
        self.page = page
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

private final class OrderedHistoryPageClient: SessionStoreAPIClient {
    let projectsResult: [AgentProject]
    let page: SessionsPage
    var requestedMessageCursors: [String?] = []
    private var historyContinuations: [CheckedContinuation<HistoryMessagesPage, Never>] = []
    private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

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
        await withCheckedContinuation { continuation in
            historyContinuations.append(continuation)
            requestedMessageCursors.append(before)
            notifyRequestCountWaiters()
        }
    }

    func waitForHistoryRequestCount(_ count: Int) async {
        guard historyContinuations.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            guard historyContinuations.count < count else {
                continuation.resume()
                return
            }
            requestCountWaiters.append((count, continuation))
        }
    }

    func resolveHistoryRequest(at index: Int, with page: HistoryMessagesPage) {
        historyContinuations[index].resume(returning: page)
    }

    private func notifyRequestCountWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in requestCountWaiters {
            if historyContinuations.count >= waiter.0 {
                waiter.1.resume()
            } else {
                pending.append(waiter)
            }
        }
        requestCountWaiters = pending
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
extension ConversationDataFlowTests {
    func testCodexAppServerConnectionMatchesResponsesByRequestID() async throws {
        let transport = FakeCodexAppServerTransport()
        let connection = CodexAppServerConnection(transport: transport, requestTimeout: 2)
        let connectTask = Task {
            try await connection.connect(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:7777/api/app-server/ws")), token: "test-token")
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
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
        XCTAssertEqual(initialize.method, "initialize")
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
        let followUpMessages = try await waitForFakeAppServerMessages(transport, count: 5)
        let followUpTurnStart = try decodeAppServerRequest(followUpMessages[4])
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

        socket.disconnect()
    }

    func testCodexAppServerRuntimeRejectsUntrustedGatewayURLBeforeConnecting() async throws {
        let project = AgentProject(id: "proj_direct", name: "Direct", path: "/tmp/direct")
        let config = makeDirectAppServerConfig(
            project: project,
            gatewayWSURL: "ws://evil.example/api/app-server/ws"
        )
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://100.64.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { config }
        )

        do {
            try await runtime.validateDirectGateway()
            XCTFail("Expected untrusted gateway URL to be rejected")
        } catch CodexAppServerSessionRuntimeError.untrustedGatewayURL {
            XCTAssertNil(pool.transport(at: 0))
        } catch {
            XCTFail("Expected untrustedGatewayURL, got \(error)")
        }
    }

    func testCodexAppServerRuntimeRejectsPublicGatewayOnDifferentPortBeforeConnecting() async throws {
        let project = AgentProject(id: "proj_direct", name: "Direct", path: "/tmp/direct")
        let config = makeDirectAppServerConfig(
            project: project,
            gatewayWSURL: "wss://agent.example.com:9443/api/app-server/ws"
        )
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "https://agent.example.com",
            token: "outer-token",
            transportFactory: { pool.make() },
            configProvider: { config }
        )

        do {
            try await runtime.validateDirectGateway()
            XCTFail("Expected gateway URL with mismatched public port to be rejected")
        } catch CodexAppServerSessionRuntimeError.untrustedGatewayURL {
            XCTAssertNil(pool.transport(at: 0))
        } catch {
            XCTFail("Expected untrustedGatewayURL, got \(error)")
        }
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

        transport.enqueue(#"{"method":"serverRequest/resolved","params":{"requestId":"cmd_resolved"}}"#)
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
        XCTAssertEqual(page.messages.map(\.kind), [.message, .reasoningSummary, .reasoningSummary, .reasoningSummary, .commandSummary, .message])
        XCTAssertEqual(page.messages.last?.createdAt, Date(timeIntervalSince1970: 1780490134))

        let conversationStore = ConversationStore()
        conversationStore.setHistory(page.messages, sessionID: "thr_processed")
        let items = ConversationTimelineItemBuilder.items(from: conversationStore.messages(for: "thr_processed"))

        XCTAssertEqual(items.count, 3)
        guard case .processed(let group) = items[1] else {
            return XCTFail("thread/read 过程 item 应折叠到最终 assistant 前")
        }
        XCTAssertEqual(group.messages.count, 4)
        XCTAssertEqual(group.title, "已处理 34s")
        guard case .message(let final) = items[2] else {
            return XCTFail("最终 assistant 应保持独立展开")
        }
        XCTAssertEqual(final.role, .assistant)
        XCTAssertEqual(final.content, "程序员相亲，对方问：你会浪漫吗？")
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

    func testDirectRuntimeDropsAncientReplayedApprovalEvenWhenItsTurnIsStillActive() async throws {
        // 现场复现：thread 早期 on-request 阶段有一条提权审批一直没 terminal 化，后来 thread 切到 never
        // 又跑了很多 turn。app-server 仍把这条旧审批所在的 turn 报成 active（activeTurnID 与审批 turnId
        // 相同），并在 resume 时重放它。仅靠 turn 比对无法识别，必须靠 startedAtMs 兜底。
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

        // startedAtMs=1000 表示 1970 年（远超过期阈值）；availableDecisions 只有 accept/cancel，没有 decline。
        transport.enqueue(#"{"id":6262,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_ancient","turnId":"turn_ancient","itemId":"cmd_ancient","startedAtMs":1000,"command":"/bin/zsh -lc 'xcrun devicectl list devices'","availableDecisions":["accept","cancel"]}}"#)

        let release = try await waitForFakeAppServerResponse(transport, id: .int(6262))
        // 必须用 availableDecisions 里真实支持的 cancel 释放，而不是 app-server 不认的 decline。
        XCTAssertEqual(release.result?["decision"]?.stringValue, "cancel")

        XCTAssertFalse(events.contains {
            if case .approvalRequest = $0 {
                return true
            }
            return false
        }, "22 小时前、turn 已被取代的旧审批不应再弹成审批卡")

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
        let turnMessages = try await waitForFakeAppServerMessages(secondTransport, count: 4)
        let turnStart = try decodeAppServerRequest(turnMessages[3])
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
        XCTAssertEqual(secondSentMessages.count, 4)
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
        let threadStart = try decodeAppServerRequest(threadMessages[3])
        XCTAssertEqual(threadStart.method, "thread/start")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_store_direct","sessionId":"thr_store_direct","preview":"帮我验收 direct Store","ephemeral":false,"modelProvider":"openai","createdAt":1780490100,"updatedAt":1780490101,"status":{"type":"idle"},"path":null,"cwd":"/tmp/store-direct","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Store 直连","turns":[]}}}"#)

        let turnMessages = try await waitForFakeAppServerMessages(transport, count: 5)
        let turnStart = try decodeAppServerRequest(turnMessages[4])
        XCTAssertEqual(turnStart.method, "turn/start")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: turnStart.id)),"result":{"turn":{"id":"turn_store_direct","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490102,"completedAt":null,"durationMs":null}}}"#)
        let historyMessages = try await waitForFakeAppServerMessages(transport, count: 6)
        let historyRead = try decodeAppServerRequest(historyMessages[5])
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

        let sendTask = Task { await store.sendPrompt("继续排查") }
        let resumeMessages = try await waitForFakeAppServerMessages(transport, count: 5)
        let resumeRequest = try decodeAppServerRequest(resumeMessages[4])
        XCTAssertEqual(resumeRequest.method, "thread/resume")
        XCTAssertEqual(resumeRequest.params?.objectValue?["threadId"]?.stringValue, "thr_idle_history")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: resumeRequest.id)),"result":{"thread":{"id":"thr_idle_history","sessionId":"thr_idle_history","preview":"继续排查","ephemeral":false,"modelProvider":"openai","createdAt":1780490300,"updatedAt":1780490302,"status":{"type":"idle"},"path":null,"cwd":"/tmp/direct-history","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"历史 idle","turns":[]}}}"#)

        let turnMessages = try await waitForFakeAppServerMessages(transport, count: 6)
        let turnStart = try decodeAppServerRequest(turnMessages[5])
        XCTAssertEqual(turnStart.method, "turn/start")
        XCTAssertEqual(turnStart.params?.objectValue?["threadId"]?.stringValue, "thr_idle_history")
        XCTAssertEqual(turnStart.params?.objectValue?["clientUserMessageId"]?.stringValue?.isEmpty, false)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: turnStart.id)),"result":{"turn":{"id":"turn_idle_history","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490303,"completedAt":null,"durationMs":null}}}"#)

        let sent = await sendTask.value
        XCTAssertTrue(sent)
        _ = try await waitForConversationMessages(in: conversationStore, sessionID: "thr_idle_history") {
            $0.contains { $0.content == "已继续这个 Codex 历史会话。" }
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
            XCTAssertEqual(message.kind, .reasoningSummary)
            XCTAssertEqual(message.content, "检查上下文并给出答案。")
            XCTAssertNil(context)
        } else {
            XCTFail("Expected plan processItemCompleted")
        }

        let commandCompleted = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_demo","turnId":"turn_demo","item":{"type":"commandExecution","id":"cmd_1","command":"go test ./...","cwd":"/tmp/demo","status":"completed","aggregatedOutput":"ok","exitCode":0}}}"#)
        if case .processItemCompleted(let message, let context, _) = try XCTUnwrap(projector.project(commandCompleted)) {
            XCTAssertEqual(message.role, .system)
            XCTAssertEqual(message.kind, .commandSummary)
            XCTAssertTrue(message.content.contains("命令：go test ./..."))
            XCTAssertTrue(message.content.contains("输出：\nok"))
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
                    SessionContextTask(id: "cmd_waiting", kind: "command", title: "Codex 请求执行命令：curl -I https://example.com", subtitle: "high", status: "waiting"),
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
        XCTAssertEqual(threadParams["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(threadParams["approvalsReviewer"]?.stringValue, "user")
        XCTAssertEqual(threadParams["sandbox"]?.stringValue, "workspace-write")
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
        XCTAssertEqual(turnParams["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(turnParams["approvalsReviewer"]?.stringValue, "user")
        XCTAssertEqual(turnParams["clientUserMessageId"]?.stringValue, "client_safe")
        let sandbox = try XCTUnwrap(turnParams["sandboxPolicy"]?.objectValue)
        XCTAssertEqual(sandbox["type"]?.stringValue, "workspaceWrite")
        XCTAssertEqual(sandbox["networkAccess"]?.boolValue, false)
        XCTAssertEqual(sandbox["writableRoots"]?.arrayValue?.compactMap(\.stringValue), [project.path])

        XCTAssertThrowsError(try builder.threadStart(cwd: "/tmp/not-allowlisted"))
        XCTAssertThrowsError(try builder.turnStart(threadID: "thr_safe", cwd: "/tmp/not-allowlisted", prompt: "hi"))
        XCTAssertThrowsError(try builder.validateRemoteSafeParams(
            .object(["cwd": .string(project.path), "approvalPolicy": .string("never")]),
            projectPath: project.path
        ))
        XCTAssertThrowsError(try builder.validateRemoteSafeParams(
            .object(["cwd": .string(project.path), "sandbox": .string("danger-full-access")]),
            projectPath: project.path
        ))
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
    XCTAssertEqual(initialize.method, "initialize")
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
    gatewayWSURL: String? = nil
) -> CodexAppServerConfigResponse {
    CodexAppServerConfigResponse(
        gatewayWSURL: gatewayWSURL ?? (gatewayAvailable ? "ws://127.0.0.1:7777/api/app-server/ws" : ""),
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
        projects: [project],
        policy: CodexAppServerPolicyMetadata(
            allowedMethods: ["initialize", "initialized", "thread/list", "thread/start", "thread/read", "turn/start", "turn/interrupt"],
            projectsSource: "agentd_allowlist"
        )
    )
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
    resumeID: String? = nil,
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
        resumeID: resumeID,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: updatedAt
    )
}
