import XCTest
import SwiftUI
import SnapshotTesting
@testable import CodexAgentPad

@MainActor
final class ConversationSnapshotTests: XCTestCase {
    // 固定尺寸 + 固定内容，专门锁住气泡对齐这类纯视觉回归（user 贴右、assistant/system 贴左）。
    // 使用模拟器默认外观，避免 snapshot 基准图和真实首屏默认 UI 不一致。
    // 首次运行会自动录制参考图到 __Snapshots__/，之后逐像素对比。
    private func makeSeededConversation() -> some View {
        let sessionID = "snapshot_session"
        let conversationStore = ConversationStore()
        let themeStore = makeThemeStore()

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
            .environmentObject(themeStore)
            .frame(width: 1024, height: 768)
    }

    private func makeRichMarkdownConversation() -> some View {
        let sessionID = "snapshot_markdown_session"
        let conversationStore = ConversationStore()
        let themeStore = makeThemeStore()
        let markdown = """
        # Markdown 验收

        这段包含 **粗体**、*斜体*、~~删除线~~、`inline code` 和 [安全链接](https://example.com)。

        - [x] 已完成任务
        - 普通列表项
        - [ ] 待处理任务

        > 引用内容保持克制缩进，不应该压迫主文本。

        | 指标 | 数值 | 状态 |
        |:---|---:|:---:|
        | latency | 42 | ok |
        | tokens | 1280 | warn |

        ```swift
        let message = "hello markdown"
        print(message)
        ```
        """

        conversationStore.applyAssistantDelta(
            AgentDelta(text: markdown, role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: "turn_markdown",
                itemID: "item_markdown",
                messageID: nil,
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
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
            .environmentObject(themeStore)
            .frame(width: 1024, height: 768)
    }

    func testConversationBubbleAlignment() {
        assertSnapshot(
            of: makeSeededConversation(),
            as: .image(precision: 0.98, layout: .fixed(width: 1024, height: 768))
        )
    }

    func testRichMarkdownConversationRendering() {
        assertSnapshot(
            of: makeRichMarkdownConversation(),
            as: .image(precision: 0.98, layout: .fixed(width: 1024, height: 768))
        )
    }

    func testEmptyConversationState() {
        let conversationStore = ConversationStore()
        let themeStore = makeThemeStore()
        let sessionStore = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        // 未选中会话 → 空状态占位。
        let view = ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .frame(width: 1024, height: 768)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 1024, height: 768))
        )
    }

    func testProjectSessionDashboard() async {
        let project = AgentProject(id: "codex-ipad-agent", name: "codex-ipad-agent", path: "/Users/me/code/codex-ipad-agent")
        let themeStore = makeThemeStore()
        let sessions = [
            makeSnapshotSession(
                id: "running",
                project: project,
                title: "接入 Codex app-server runtime",
                status: "running",
                preview: "正在把 assistant_delta 合并到稳定消息气泡里。",
                activeTurnID: "turn-running",
                usage: UsageSummary(inputTokens: 4_200, outputTokens: 960, totalTokens: 5_160, costUSD: Decimal(string: "0.0312")),
                rateLimit: RateLimitSummary(remainingRequests: 18, remainingTokens: nil, resetAt: nil)
            ),
            makeSnapshotSession(
                id: "approval",
                project: project,
                title: "确认文件变更审批",
                status: "waiting_for_approval",
                preview: "agentd 捕获到 patchUpdated，需要在 iPad 上明确批准。",
                pendingApproval: ApprovalSummary(id: "approval-1", title: "写入 diff", kind: "file_change", count: 2)
            ),
            makeSnapshotSession(
                id: "history",
                project: project,
                title: "历史会话分页加载",
                status: "history",
                preview: "只加载最近消息，向上滚动时再按 cursor 补旧内容。"
            ),
            makeSnapshotSession(
                id: "done",
                project: project,
                title: "README 迁移说明",
                status: "completed",
                preview: "记录 Tailscale、Token、app-server 本机监听和 PTY fallback。"
            )
        ]
        let sessionStore = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: {
                SnapshotSessionAPIClient(projects: [project], sessions: sessions)
            }
        )
        await sessionStore.refreshAll(autoAttach: false)

        let view = NavigationStack {
            ProjectSidebarView(showsSessions: true)
                .toolbar(.hidden, for: .navigationBar)
        }
        .environmentObject(sessionStore)
        .environmentObject(themeStore)
        .frame(width: 420, height: 768)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 420, height: 768))
        )
    }

    func testAppearancePreview() {
        let defaults = UserDefaults(suiteName: "ConversationSnapshotTests.Appearance.\(UUID().uuidString)")!
        let themeStore = ThemeStore(defaults: defaults)
        themeStore.mode = .dark
        themeStore.preset = .gruvbox
        themeStore.uiFontPreset = .rounded
        themeStore.codeFontPreset = .menlo
        themeStore.setFontScale(1.1)

        let view = NavigationStack {
            AppearanceView()
        }
        .environmentObject(themeStore)
        .environment(\.colorScheme, .dark)
        .frame(width: 560, height: 1180)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 560, height: 1180))
        )
    }

    private func makeThemeStore() -> ThemeStore {
        let suiteName = "ConversationSnapshotTests.Theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ThemeStore(defaults: defaults)
    }

    private func makeSnapshotSession(
        id: String,
        project: AgentProject,
        title: String,
        status: String,
        preview: String,
        activeTurnID: TurnID? = nil,
        usage: UsageSummary? = nil,
        rateLimit: RateLimitSummary? = nil,
        pendingApproval: ApprovalSummary? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: title,
            status: status,
            source: "codex",
            resumeID: "thread-\(id)",
            createdAt: nil,
            updatedAt: nil,
            preview: preview,
            activeTurnID: activeTurnID,
            lastSeq: 42,
            revision: 3,
            usage: usage,
            rateLimit: rateLimit,
            pendingApproval: pendingApproval
        )
    }
}

private enum SnapshotAPIError: Error {
    case unimplemented
}

private struct SnapshotSessionAPIClient: SessionStoreAPIClient {
    let projects: [AgentProject]
    let sessions: [AgentSession]

    func projects() async throws -> [AgentProject] {
        projects
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        let filtered = projectID.map { id in sessions.filter { $0.projectID == id } } ?? sessions
        guard let limit else {
            return filtered
        }
        return Array(filtered.prefix(limit))
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        SessionsPage(sessions: try await sessions(projectID: projectID, cursor: cursor, limit: limit))
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw SnapshotAPIError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw SnapshotAPIError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw SnapshotAPIError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        throw SnapshotAPIError.unimplemented
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        throw SnapshotAPIError.unimplemented
    }

    func websocketURL(sessionID: String) throws -> URL {
        throw SnapshotAPIError.unimplemented
    }
}
