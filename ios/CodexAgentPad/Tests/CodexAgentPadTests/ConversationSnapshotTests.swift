import XCTest
import SwiftUI
import SnapshotTesting
@testable import CodexAgentPad

@MainActor
final class ConversationSnapshotTests: XCTestCase {
    // 固定尺寸 + 固定内容，专门锁住气泡对齐这类纯视觉回归（user 贴右、assistant/system 贴左）。
    // 首次运行会自动录制参考图到 __Snapshots__/，之后逐像素对比。
    private func makeSeededConversation() -> some View {
        let sessionID = "snapshot_session"
        let conversationStore = ConversationStore()

        conversationStore.appendSystem("Codex 交互式会话已启动。", sessionID: sessionID)
        conversationStore.appendUser("2216", sessionID: sessionID)
        conversationStore.applyAssistantDelta(
            AgentDelta(text: "这是助手的回复，应当靠左对齐，使用低对比中性气泡。", role: .assistant, kind: .message),
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
        conversationStore.appendUser(
            "这是一条比较长的用户消息，用来验证多行情况下蓝色气泡依然贴右对齐，而不是漂到屏幕中间。",
            sessionID: sessionID
        )
        // 发送失败：验证红色状态标记出现在用户气泡左侧。
        conversationStore.appendLocalUser(
            "这条发送失败了",
            sessionID: sessionID,
            clientMessageID: "failed-1",
            sendStatus: .failed
        )

        let sessionStore = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        sessionStore.selectedSessionID = sessionID

        return ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .frame(width: 1024, height: 768)
    }

    func testConversationBubbleAlignment() {
        assertSnapshot(
            of: makeSeededConversation(),
            as: .image(precision: 0.98, layout: .fixed(width: 1024, height: 768))
        )
    }

    func testEmptyConversationState() {
        let conversationStore = ConversationStore()
        let sessionStore = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        // 未选中会话 → 空状态占位。
        let view = ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .frame(width: 1024, height: 768)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 1024, height: 768))
        )
    }
}
