import XCTest
import Combine
@testable import CodexAgentPad

@MainActor
final class ConversationDataFlowTests: XCTestCase {
    func testThemeStorePersistsThemeAccentAndFontScale() throws {
        let suiteName = "ThemeStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ThemeStore(defaults: defaults)
        XCTAssertEqual(store.mode, .system)
        XCTAssertEqual(store.accent, .blue)
        XCTAssertEqual(store.fontScale, 1.0, accuracy: 0.001)

        let initialVersion = store.themeVersion
        store.mode = .dark
        store.accent = .orange
        store.setFontScale(1.2)

        XCTAssertEqual(store.mode, .dark)
        XCTAssertEqual(store.accent, .orange)
        XCTAssertEqual(store.fontScale, 1.2, accuracy: 0.001)
        XCTAssertGreaterThan(store.themeVersion, initialVersion)

        let reloaded = ThemeStore(defaults: defaults)
        XCTAssertEqual(reloaded.mode, .dark)
        XCTAssertEqual(reloaded.accent, .orange)
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

    func testMessageRenderPlanCacheReusesAppendOnlyStreamingPrefix() {
        let cache = MessageRenderPlanCache(limit: 4)
        var message = ConversationMessage(
            stableID: "assistant:render",
            role: .assistant,
            content: "先解释一下\n```swift\nlet a = 1\n",
            sendStatus: .sending
        )

        let first = cache.plan(for: message)
        XCTAssertEqual(first.segments.count, 2)
        XCTAssertEqual(first.openCodeFenceLanguage, "swift")

        message.content += "let b = 2\n```"
        let second = cache.plan(for: message)

        XCTAssertEqual(cache.incrementalReuseCountForTesting, 1)
        XCTAssertEqual(second.messageKey, "assistant:render")
        XCTAssertNil(second.openCodeFenceLanguage)
        XCTAssertTrue(second.segments.contains { $0.kind == .code && $0.text.contains("let b = 2") })
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
        themeStore.accent = .teal
        themeStore.setFontScale(1.2)

        let afterMessages = conversationStore.messages(for: sessionID)
        XCTAssertEqual(afterMessages.map(\.id), beforeMessages.map(\.id))
        XCTAssertEqual(afterMessages.map(\.stableID), beforeMessages.map(\.stableID))
        XCTAssertEqual(try XCTUnwrap(afterMessages.first).renderFingerprint, beforePlan)
        XCTAssertEqual(conversationStore.lastSeenSeq(for: sessionID), 12)
        XCTAssertEqual(MessageRenderPlanCache(limit: 4).plan(for: try XCTUnwrap(afterMessages.first)).segments, renderPlan.segments)
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

    func testLegacyHistoryDeduplicatesClientMessageEcho() {
        let store = ConversationStore()
        let sessionID = "sess_client_echo_legacy_history"
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

    func testRepeatedLegacyHistoryProjectionKeepsMessageIdentity() {
        let store = ConversationStore()
        let sessionID = "sess_legacy_history_projection"
        let createdAt = Date(timeIntervalSince1970: 100)

        store.setHistory([
            CodexHistoryMessage(role: "user", content: "旧历史问题", createdAt: createdAt),
            CodexHistoryMessage(role: "assistant", content: "旧历史回答", createdAt: createdAt.addingTimeInterval(1))
        ], sessionID: sessionID)
        let firstIDs = store.messages(for: sessionID).map(\.id)

        // legacy rollout 没有稳定 id，解码时会补随机 UUID；语义相同的历史页重复绑定时，
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

    func testGrowingLegacyHistoryProjectionReusesExistingRows() {
        let store = ConversationStore()
        let sessionID = "sess_growing_legacy_history"
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

    func testHistoryMergePreservesRepeatedLegacyMessagesWithSameText() {
        let store = ConversationStore()
        let sessionID = "sess_repeated_legacy_text"

        store.setHistory([
            CodexHistoryMessage(role: "user", content: "继续", createdAt: Date(timeIntervalSince1970: 10)),
            CodexHistoryMessage(role: "user", content: "继续", createdAt: Date(timeIntervalSince1970: 20))
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map(\.content), ["继续", "继续"])
        XCTAssertNotEqual(messages[0].id, messages[1].id)
    }

    func testLegacyEchoMergeRequiresNearbyHistoryTimestamp() {
        let store = ConversationStore()
        let sessionID = "sess_legacy_echo_window"

        store.appendUser("继续", sessionID: sessionID)
        store.setHistory([
            CodexHistoryMessage(role: "user", content: "继续", createdAt: Date(timeIntervalSince1970: 10))
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.filter { $0.role == .user && $0.content == "继续" }.count, 2)
    }

    func testAssistantStreamUpdatesExistingAssistantRow() async throws {
        let store = ConversationStore()
        let sessionID = "sess_stream_merge"

        store.appendUser("开始", sessionID: sessionID)
        store.ingestTerminalOutput("│ • 第一段回复\n", sessionID: sessionID)

        var messages = try await waitForConversationMessages(in: store, sessionID: sessionID) { messages in
            messages.count == 2 && messages.last?.role == .assistant && messages.last?.content == "第一段回复"
        }
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertEqual(messages.last?.content, "第一段回复")

        // 第二段 assistant 输出应该复用最后一条 assistant 行，避免流式 delta 重放造成重复气泡。
        store.ingestTerminalOutput("│ • 第二段回复\n继续内容\n", sessionID: sessionID)

        messages = try await waitForConversationMessages(in: store, sessionID: sessionID) { messages in
            messages.count == 2
                && messages.last?.role == .assistant
                && messages.last?.content.contains("第二段回复") == true
                && messages.last?.content.contains("继续内容") == true
        }
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertTrue(messages.last?.content.contains("第二段回复") == true)
        XCTAssertTrue(messages.last?.content.contains("继续内容") == true)
        XCTAssertFalse(messages.last?.content.contains("第一段回复") == true)
    }

    func testRepeatedAssistantCandidateDoesNotDuplicateRows() async throws {
        let store = ConversationStore()
        let sessionID = "sess_replay"

        store.ingestTerminalOutput("│ • 可重放的回复\n", sessionID: sessionID)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(store.messages(for: sessionID).count, 1)

        // 重连后同一段输出可能再次到达；内容未变化时 reducer 不应增加新消息。
        store.ingestTerminalOutput("│ • 可重放的回复\n", sessionID: sessionID)
        try await Task.sleep(nanoseconds: 1_100_000_000)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .assistant)
        XCTAssertEqual(messages.first?.content, "可重放的回复")
    }

    func testHistoryAssistantSuppressesDuplicateRecentOutputFallback() async throws {
        let store = ConversationStore()
        let sessionID = "sess_history_recent_output_dedup"
        let answer = """
        一个程序员去买菜。

        老板说：“黄瓜 3 块一斤，西红柿 4 块一斤。”

        程序员沉思片刻：“你这个接口不太 RESTful，建议统一资源定价。”
        """

        store.setHistory([
            CodexHistoryMessage(id: "rollout:100", role: "user", content: "讲个笑话", createdAt: Date(timeIntervalSince1970: 10)),
            CodexHistoryMessage(id: "rollout:200", role: "assistant", content: answer, createdAt: Date(timeIntervalSince1970: 11))
        ], sessionID: sessionID)

        // 手动刷新运行中会话时，rollout 已经有干净历史；recent_output 里仍可能残留同一段 PTY 尾部。
        store.ingestTerminalOutput(
            """
            │ • 一个程序员去买菜。 ›Implement {feature}gpt-5.5 xhigh fast · ~/code
            老板说：“黄瓜 3 块一斤，西红柿 4 块一斤。”
            程序员沉思片刻：“你这个接口不太 RESTful，建议统一资源定价。”
            """,
            sessionID: sessionID
        )
        try await Task.sleep(nanoseconds: 1_100_000_000)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.last?.content, answer)
    }

    func testTerminalParserStripsInlinePromptFragment() async throws {
        let store = ConversationStore()
        let sessionID = "sess_inline_prompt_clean"

        store.ingestTerminalOutput(
            """
            │ • 一个程序员去买菜。 ›Implement {feature}gpt-5.5 xhigh fast · ~/code
            老板说：“黄瓜 3 块一斤，西红柿 4 块一斤。”
            """,
            sessionID: sessionID
        )
        try await Task.sleep(nanoseconds: 1_100_000_000)

        let message = try XCTUnwrap(store.messages(for: sessionID).first)
        XCTAssertEqual(message.role, .assistant)
        XCTAssertTrue(message.content.contains("一个程序员去买菜。"))
        XCTAssertFalse(message.content.contains("Implement"))
    }

    func testTerminalParserCollapsesRepeatedSentenceRedraws() async throws {
        let store = ConversationStore()
        let sessionID = "sess_sentence_redraw_collapse"

        store.ingestTerminalOutput(
            """
            │ • 产品经理问程序员：“这个需求多久能做完？” 产品经理问程序员：“这个需求多久能做完？” 产品经理问程序员：“这个需求多久能做完？”
            程序员：“如果不改需求，三天。” 程序员：“如果不改需求，三天。” 程序员：“如果不改需求，三天。”
            产品经理：“那要是中途改呢？” 产品经理：“那要是中途改呢？” 产品经理：“那要是中途改呢？”
            程序员：“那就一直很新鲜，永远在开发中。”
            程序员：“那就一直很新鲜，永远在开发中。”
            程序员：“那就一直很新鲜，永远在开发中。”
            """,
            sessionID: sessionID
        )
        try await Task.sleep(nanoseconds: 1_100_000_000)

        let message = try XCTUnwrap(store.messages(for: sessionID).first)
        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(occurrenceCount(of: "产品经理问程序员", in: message.content), 1)
        XCTAssertEqual(occurrenceCount(of: "如果不改需求", in: message.content), 1)
        XCTAssertEqual(occurrenceCount(of: "那要是中途改呢", in: message.content), 1)
        XCTAssertEqual(occurrenceCount(of: "永远在开发中", in: message.content), 1)
    }

    func testHistoryRefreshRemovesDirtyRepeatedTerminalAssistant() async throws {
        let store = ConversationStore()
        let sessionID = "sess_refresh_removes_dirty_terminal_assistant"
        let answer = """
        产品经理问程序员：“这个需求多久能做完？”

        程序员：“如果不改需求，三天。”

        产品经理：“那要是中途改呢？”

        程序员：“那就一直很新鲜，永远在开发中。”
        """

        store.appendLocalUser("继续", sessionID: sessionID, clientMessageID: "client-continue", sendStatus: .sent)
        store.ingestTerminalOutput(
            """
            │ • 产品经理问程序员：“这个需求多久能做完？” 产品经理问程序员：“这个需求多久能做完？” 产品经理问程序员：“这个需求多久能做完？”
            程序员：“如果不改需求，三天。” 程序员：“如果不改需求，三天。” 程序员：“如果不改需求，三天。”
            产品经理：“那要是中途改呢？” 产品经理：“那要是中途改呢？” 产品经理：“那要是中途改呢？”
            程序员：“那就一直很新鲜，永远在开发中。”
            程序员：“那就一直很新鲜，永远在开发中。”
            程序员：“那就一直很新鲜，永远在开发中。”
            """,
            sessionID: sessionID
        )
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(store.messages(for: sessionID).filter { $0.role == .assistant }.count, 1)

        let now = Date()
        store.setHistory([
            CodexHistoryMessage(role: "user", content: "继续", createdAt: now),
            CodexHistoryMessage(role: "assistant", content: answer, createdAt: now.addingTimeInterval(1))
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.map(\.content), ["继续", answer])
        XCTAssertEqual(messages.filter { $0.role == .assistant }.count, 1)
    }

    func testTerminalOutputBoundedWindowKeepsLatestTail() async throws {
        let store = ConversationStore()
        let sessionID = "sess_terminal_tail_window"
        let oldPrefix = "│ • 旧回复不应保留\n"
        let filler = String(repeating: "x", count: 18_000)

        store.ingestTerminalOutput(oldPrefix + filler + "\n│ • 最新尾部回复\n", sessionID: sessionID)
        try await Task.sleep(nanoseconds: 1_100_000_000)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .assistant)
        XCTAssertTrue(messages.first?.content.contains("最新尾部回复") == true)
        XCTAssertFalse(messages.first?.content.contains("旧回复不应保留") == true)
    }

    func testAgentEventDecodesLegacyAndStructuredAssistantDelta() throws {
        let decoder = JSONDecoder()

        let output = try decoder.decode(AgentEvent.self, from: Data(#"{"type":"output","data":"hello","seq":6,"session_id":"sess_output"}"#.utf8))
        if case .output(let data, let meta) = output {
            XCTAssertEqual(data, "hello")
            XCTAssertEqual(meta.seq, 6)
            XCTAssertEqual(meta.sessionID, "sess_output")
        } else {
            XCTFail("Expected output event")
        }

        let assistantDelta = try decoder.decode(
            AgentEvent.self,
            from: Data(#"{"type":"assistant_delta","delta":{"text":"结构化增量","role":"assistant","kind":"message"}}"#.utf8)
        )
        if case .assistantDelta(let delta, _) = assistantDelta {
            XCTAssertEqual(delta.text, "结构化增量")
        } else {
            XCTFail("Expected assistant delta event")
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

    func testMessagePageResponseMapsToLegacyHistoryMessages() throws {
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

    func testLegacyMessagesResponsePreservesCursorAndClientMessageIDFallback() throws {
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

        let legacyDelta = try decoder.decode(
            StructuredAgentEvent.self,
            from: Data(#"{"type":"assistant_delta","data":"兼容增量","seq":8,"session_id":"sess_1","message_id":"msg_1"}"#.utf8)
        )
        if case .assistantDelta(let delta, let meta) = legacyDelta {
            XCTAssertEqual(delta.text, "兼容增量")
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

    func testSessionStoreAutoAttachKeepsExplicitHistorySelection() async {
        let project = makeProject(id: "proj_1")
        let selectedHistory = makeSession(id: "codex_selected", projectID: project.id, title: "用户点选的历史", status: "history", source: "codex", resumeID: "selected")
        let latestRunning = makeSession(id: "sess_latest", projectID: project.id, title: "最新运行会话", status: "running", source: "agentd")
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

        XCTAssertEqual(client.requestedProjectIDs.compactMap { $0 }, [project.id, project.id])
        XCTAssertEqual(store.selectedSessionID, selectedHistory.id)
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertTrue(conversationStore.hasLoadedHistory(sessionID: selectedHistory.id))
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
        let created = makeSession(id: "sess_created", projectID: project.id, title: "刚创建", status: "closed", source: "agentd")
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
            source: "agentd",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let client = MutableSessionPageClient(projects: [project], page: SessionsPage(sessions: [history, running]))
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

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
            source: "agentd"
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

    func testRefreshCurrentContextUsesRunningRecentOutputAsConversationFallback() async throws {
        let project = makeProject(id: "proj_1")
        let running = makeSession(id: "sess_running", projectID: project.id, title: "运行中", status: "running", source: "agentd")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            sessionResponses: [
                running.id: try makeSessionResponse(session: running, recentOutput: "│ • 从 Mac 回来的回复\n", lastSeq: 12)
            ]
        )
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: logStore,
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        store.selectedSessionID = running.id
        await store.refreshCurrentContext()
        try await Task.sleep(nanoseconds: 1_100_000_000)

        XCTAssertEqual(client.requestedSessionIDs, [running.id])
        XCTAssertTrue(logStore.log(for: running.id).contains("从 Mac 回来的回复"))
        let messages = conversationStore.messages(for: running.id)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .assistant)
        XCTAssertEqual(messages.first?.content, "从 Mac 回来的回复")
    }

    func testWebSocketOutputCreatesAssistantFallbackBubble() async throws {
        let project = makeProject(id: "proj_1")
        let running = makeSession(id: "sess_ws_output", projectID: project.id, title: "运行中", status: "running", source: "agentd")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
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

        sockets[0].emitEvent(.output(
            "│ • 来自 PTY 的回复\n",
            AgentEventMetadata(
                seq: 1,
                sessionID: running.id,
                turnID: nil,
                itemID: nil,
                messageID: nil,
                clientMessageID: nil,
                revision: nil,
                createdAt: nil
            )
        ))
        try await Task.sleep(nanoseconds: 1_100_000_000)

        XCTAssertTrue(logStore.log(for: running.id).contains("来自 PTY 的回复"))
        let messages = conversationStore.messages(for: running.id)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .assistant)
        XCTAssertEqual(messages.first?.content, "来自 PTY 的回复")
    }

    func testWebSocketOutputAndLogDeltaWithSameSeqDoNotDuplicateLog() async throws {
        let project = makeProject(id: "proj_1")
        let running = makeSession(id: "sess_ws_log_dedupe", projectID: project.id, title: "运行中", status: "running", source: "agentd")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
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

        let metadata = AgentEventMetadata(
            seq: 7,
            sessionID: running.id,
            turnID: nil,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )
        sockets[0].emitEvent(.output("同一个 seq 的日志块\n", metadata))
        sockets[0].emitEvent(.logDelta(LogDelta(text: "同一个 seq 的日志块\n", stream: nil), metadata))
        try await Task.sleep(nanoseconds: 250_000_000)

        let log = logStore.log(for: running.id)
        XCTAssertEqual(occurrenceCount(of: "同一个 seq 的日志块", in: log), 1)
        XCTAssertEqual(logStore.lastSeq(for: running.id), 7)
        XCTAssertTrue(conversationStore.messages(for: running.id).isEmpty)
    }

    func testStructuredAssistantMessageCreatesBubbleWhileOutputStaysLogOnly() async throws {
        let project = makeProject(id: "proj_1")
        let running = makeSession(id: "sess_structured_assistant_live", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
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

        sockets[0].emitEvent(.output(
            "│ • 这只是 PTY 日志\n",
            AgentEventMetadata(seq: 1, sessionID: running.id, turnID: nil, itemID: nil, messageID: nil, clientMessageID: nil, revision: nil, createdAt: nil)
        ))
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
        XCTAssertTrue(logStore.log(for: running.id).contains("这只是 PTY 日志"))
        XCTAssertFalse(messages.contains { $0.content.contains("PTY 日志") })
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.content == "结构化助手回复" })
    }

    func testRefreshCurrentContextRequestsRunningDetailAfterLocalLogSeq() async throws {
        let project = makeProject(id: "proj_1")
        let running = makeSession(id: "sess_running", projectID: project.id, title: "运行中", status: "running", source: "agentd")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            sessionResponses: [
                running.id: try makeSessionResponse(session: running, recentOutput: nil, lastSeq: 12)
            ]
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

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        store.selectedSessionID = running.id
        await store.refreshCurrentContext()

        XCTAssertEqual(client.requestedSessionIDs, [running.id])
        XCTAssertEqual(client.requestedSessionAfterSeqs, [12])
        XCTAssertTrue(conversationStore.messages(for: running.id).isEmpty)
    }

    func testWebSocketURLIncludesReplayWatermark() throws {
        let client = MockSessionStoreClient(projects: [], sessions: [])

        let url = try client.websocketURL(sessionID: "sess_1", afterSeq: 42)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(components?.queryItems?.first { $0.name == "after_seq" }?.value, "42")
    }

    func testWebSocketConnectionAsyncStreamParsesAgentEvents() async throws {
        let connection = WebSocketConnection()
        let events = await connection.events()
        let eventExpectation = expectation(description: "收到 AsyncStream 事件")
        var receivedEvent: AgentEvent?
        let consumer = Task {
            var iterator = events.makeAsyncIterator()
            if let event = await iterator.next() {
                await MainActor.run {
                    receivedEvent = event
                    eventExpectation.fulfill()
                }
            }
        }

        await connection.ingest(.string("""
        {
          "type": "assistant_delta",
          "data": "后台解析的回复",
          "seq": 9,
          "session_id": "sess_stream"
        }
        """))
        await fulfillment(of: [eventExpectation], timeout: 1.0)
        consumer.cancel()
        await connection.finishStreams()

        let event = try XCTUnwrap(receivedEvent)
        guard case .assistantDelta(let delta, let metadata) = event else {
            XCTFail("期望 assistant_delta，实际收到 \(event)")
            return
        }
        XCTAssertEqual(delta.text, "后台解析的回复")
        XCTAssertEqual(metadata.seq, 9)
        XCTAssertEqual(metadata.sessionID, "sess_stream")
    }

    func testWebSocketConnectionParseFailureEmitsStatusStream() async throws {
        let connection = WebSocketConnection()
        let statuses = await connection.statuses()
        let statusExpectation = expectation(description: "收到解析失败状态")
        var receivedStatus: WebSocketStatus?
        let consumer = Task {
            var iterator = statuses.makeAsyncIterator()
            if let status = await iterator.next() {
                await MainActor.run {
                    receivedStatus = status
                    statusExpectation.fulfill()
                }
            }
        }

        await connection.ingest(.string("{ not json }"))
        await fulfillment(of: [statusExpectation], timeout: 1.0)
        consumer.cancel()
        await connection.finishStreams()

        let status = try XCTUnwrap(receivedStatus)
        guard case .failed(let message) = status else {
            XCTFail("期望 failed 状态，实际收到 \(status)")
            return
        }
        XCTAssertTrue(message.contains("WebSocket 消息解析失败"))
    }

    func testPendingWebSocketMessageQueueRejectsOverflowAndDrainsInOrder() {
        var queue = PendingWebSocketMessageQueue(maxMessages: 2)
        let first = ClientWebSocketMessage(type: "input", data: "第一条", clientMessageID: "client_1")
        let second = ClientWebSocketMessage(type: "input", data: "第二条", clientMessageID: "client_2")
        let overflow = ClientWebSocketMessage(type: "input", data: "第三条", clientMessageID: "client_3")

        XCTAssertTrue(queue.append(first))
        XCTAssertTrue(queue.append(second))
        XCTAssertFalse(queue.append(overflow))
        XCTAssertEqual(queue.count, 2)

        let drained = queue.drain()
        XCTAssertEqual(drained.map(\.clientMessageID), ["client_1", "client_2"])
        XCTAssertTrue(queue.isEmpty)
        XCTAssertTrue(queue.drain().isEmpty)
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
        let running = makeSession(id: "sess_ws_reconnect", projectID: project.id, title: "运行中", status: "running", source: "agentd")
        let appStore = AppStore()
        appStore.token = "test-token"
        let logStore = LogStore()
        logStore.append("旧输出", sessionID: running.id, seq: 5)
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
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
        XCTAssertEqual(queryValue("after_seq", in: sockets[0].connectedURLs.first), "5")
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        logStore.append("新输出", sessionID: running.id, seq: 7)
        sockets[0].emitStatus(.failed("network dropped"))
        for _ in 0..<50 where sockets.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(queryValue("after_seq", in: sockets[1].connectedURLs.first), "7")
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
        XCTAssertEqual(queryValue("after_seq", in: sockets[1].connectedURLs.first), "9")
        XCTAssertTrue(conversationStore.messages(for: running.id).contains { $0.content == "重连前补拉消息" })
    }

    func testReturningToSessionListCancelsQueuedWebSocketReconnect() async throws {
        let project = makeProject(id: "proj_ws_cancel")
        let running = makeSession(id: "sess_ws_cancel", projectID: project.id, title: "运行中", status: "running", source: "agentd")
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
        let running = makeSession(id: "sess_running", projectID: project.id, title: "运行中", status: "running", source: "agentd")
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        store.selectedSessionID = running.id

        XCTAssertNil(store.selectedForegroundActivity)
    }

    func testSendingPromptCreatesWaitingForegroundActivity() async throws {
        let project = makeProject(id: "proj_1")
        let created = makeSession(id: "sess_created", projectID: project.id, title: "新会话", status: "running", source: "agentd")
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
        let running = makeSession(id: "sess_retry", projectID: project.id, title: "运行中", status: "running", source: "agentd")
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

        conversationStore.appendLocalUser("请重试", sessionID: running.id, clientMessageID: "client-retry", sendStatus: .failed)
        let failedMessage = try XCTUnwrap(conversationStore.messages(for: running.id).first)

        let retried = await store.retryFailedUserMessage(failedMessage)

        XCTAssertTrue(retried)
        XCTAssertEqual(sockets[0].sentInputs.count, 1)
        XCTAssertEqual(sockets[0].sentInputs.first?.text, "请重试\r")
        XCTAssertEqual(sockets[0].sentInputs.first?.clientMessageID, "client-retry")
        let messages = conversationStore.messages(for: running.id)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.sendStatus, .sent)
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
        await store.selectSession(waiting)
        XCTAssertEqual(sockets.count, 1)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        store.decideApproval(approval, accept: true)

        XCTAssertEqual(sockets[0].sentApprovals.count, 1)
        XCTAssertEqual(sockets[0].sentApprovals.first?.approvalID, "approval-1")
        XCTAssertEqual(sockets[0].sentApprovals.first?.decision, "accept")
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

    func testStructuredAssistantSuppressesTerminalParserDuplicate() async throws {
        let store = ConversationStore()
        let sessionID = "sess_dedup"

        // 先来一段 PTY 输出，解析兜底生成一条 assistant 气泡。
        store.ingestTerminalOutput("│ • 来自终端的回复\n", sessionID: sessionID)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(store.messages(for: sessionID).count, 1)
        XCTAssertNil(store.messages(for: sessionID).first?.stableID)

        // 结构化助手消息到达：应清掉解析兜底气泡，只保留结构化这条。
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
        var messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "结构化回复")
        XCTAssertEqual(messages.first?.stableID, "item_1")

        // 之后即便再来带终端装饰的 PTY 输出，也不应追加重复气泡。
        store.ingestTerminalOutput("│ • 来自终端的回复\n›Improve documentation in @file\n", sessionID: sessionID)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "结构化回复")
    }

    func testTerminalFallbackResumesAfterNewUserWhenPriorTurnHadStructuredAssistant() async throws {
        let store = ConversationStore()
        let sessionID = "sess_fallback_after_structured"

        store.appendLocalUser("第一轮", sessionID: sessionID, clientMessageID: "client-1", sendStatus: .sent)
        let firstAssistant = try AgentAPIClient.decoder.decode(
            AgentMessage.self,
            from: Data("""
            {
              "id": "rollout:first",
              "session_id": "\(sessionID)",
              "role": "assistant",
              "kind": "message",
              "content": "第一轮结构化回复",
              "created_at": "2026-06-02T10:00:00Z",
              "revision": 1,
              "send_status": "confirmed"
            }
            """.utf8)
        )
        store.completeMessage(firstAssistant, metadata: .empty, fallbackSessionID: sessionID)

        store.appendLocalUser("第二轮", sessionID: sessionID, clientMessageID: "client-2", sendStatus: .sent)
        store.ingestTerminalOutput("│ • 第二轮来自 PTY 的临时回复\n", sessionID: sessionID)
        try await Task.sleep(nanoseconds: 1_100_000_000)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.map(\.content), ["第一轮", "第一轮结构化回复", "第二轮", "第二轮来自 PTY 的临时回复"])
        XCTAssertNil(messages.last?.stableID)
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

    private(set) var connectedURLs: [URL] = []
    private(set) var sentInputs: [(text: String, clientMessageID: ClientMessageID?)] = []
    private(set) var sentResizes: [(cols: Int, rows: Int)] = []
    private(set) var sentApprovals: [(approvalID: String, decision: String, message: String?)] = []
    private(set) var disconnectCallCount = 0

    func connect(url: URL, token: String) {
        connectedURLs.append(url)
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

    func sendEnter() -> Bool {
        true
    }

    func sendCtrlC() -> Bool {
        true
    }

    func sendResize(cols: Int, rows: Int) -> Bool {
        sentResizes.append((cols, rows))
        return true
    }

    func sendApprovalDecision(approvalID: String, decision: String, message: String?) -> Bool {
        sentApprovals.append((approvalID, decision, message))
        return true
    }

    func ping() -> Bool {
        true
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
        notifyRequestCountWaiters()
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

    func websocketURL(sessionID: String) throws -> URL {
        URL(string: "ws://127.0.0.1/\(sessionID)")!
    }

    func waitForCreateRequestCount(_ count: Int) async {
        guard createPayloads.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            guard createPayloads.count < count else {
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
            if createPayloads.count >= waiter.0 {
                waiter.1.resume()
            } else {
                pending.append(waiter)
            }
        }
        requestCountWaiters = pending
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
    let messagesError: Error?
    var requestedProjectIDs: [String?] = []
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
        self.messagesError = messagesError
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
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

    func websocketURL(sessionID: String) throws -> URL {
        URL(string: "ws://127.0.0.1/\(sessionID)")!
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

    func websocketURL(sessionID: String) throws -> URL {
        URL(string: "ws://127.0.0.1/\(sessionID)")!
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

    func websocketURL(sessionID: String) throws -> URL {
        URL(string: "ws://127.0.0.1/\(sessionID)")!
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

// 冷启动重试用的客户端：前 N 次 projects() 抛错模拟隧道未就绪，之后成功返回。
private final class FlakyBootstrapClient: SessionStoreAPIClient {
    private let failuresBeforeSuccess: Int
    private let projectsResult: [AgentProject]
    private let sessionsResult: [AgentSession]
    private(set) var projectsCallCount = 0

    init(failuresBeforeSuccess: Int, projects: [AgentProject], sessions: [AgentSession]) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
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

    func websocketURL(sessionID: String) throws -> URL {
        URL(string: "ws://127.0.0.1/\(sessionID)")!
    }
}

private enum MockError: Error {
    case unimplemented
}

private func occurrenceCount(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

private func makeProject(id: String) -> AgentProject {
    AgentProject(id: id, name: id, path: "/tmp/\(id)")
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
      "ws_url": "/api/sessions/\(session.id)/ws"\(firstMessageField)
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
