import XCTest
import SwiftUI
import UIKit
import SnapshotTesting
@testable import MimiRemote

@MainActor
final class ConversationSnapshotTests: XCTestCase {
    // 快照只验证布局和样式，消息时间固定，避免每次运行因当前分钟变化产生视觉误报。
    private let snapshotMessageDate = Date(timeIntervalSince1970: 1_782_879_660)

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 现有参考图按 iPad 渲染环境录制；Universal 后 iPhone 会使用不同 trait，
        // 容易产生设备差异误报。iPhone 适配用模拟器 smoke 和后续专属基线覆盖。
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Snapshot 基线按 iPad 设备录制，iPhone 目标跳过这组视觉基线。"
        )
    }

    func testWorkspaceOpenCurrentDirectoryButton() {
        let view = WorkspaceOpenCurrentDirectoryButton(
            directoryName: "gaixiaotongxue",
            isOpening: false,
            isDisabled: false,
            action: {}
        )
        .environmentObject(makeThemeStore())
        .environment(\.colorScheme, .light)
        .padding(20)
        .frame(width: 390, height: 110)
        .background(Color(uiColor: .systemGroupedBackground))

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 390, height: 110))
        )
    }

    // 固定尺寸 + 固定内容，专门锁住气泡对齐这类纯视觉回归（user 贴右、assistant/system 贴左）。
    // 默认保持浅色基线；需要验证深色配色时显式传入 colorScheme，避免依赖 Simulator 当前外观。
    // 首次运行会自动录制参考图到 __Snapshots__/，之后逐像素对比。
    private func makeSeededConversation(colorScheme: ColorScheme = .light) -> some View {
        let sessionID = "snapshot_session"
        let conversationStore = ConversationStore()
        let themeStore = makeThemeStore()

        conversationStore.appendSystem("Codex 交互式会话已启动。", sessionID: sessionID, createdAt: snapshotMessageDate)
        conversationStore.appendUser("2216", sessionID: sessionID, createdAt: snapshotMessageDate)
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
                createdAt: snapshotMessageDate
            ),
            fallbackSessionID: sessionID
        )
        conversationStore.appendUser(
            "这是一条比较长的用户消息，用来验证多行情况下紫色气泡依然贴右对齐，而不是漂到屏幕中间。",
            sessionID: sessionID,
            createdAt: snapshotMessageDate
        )
        // 发送失败：验证红色状态标记出现在用户气泡左侧。
        conversationStore.appendLocalUser(
            "这条发送失败了",
            sessionID: sessionID,
            clientMessageID: "failed-1",
            sendStatus: .failed,
            createdAt: snapshotMessageDate
        )

        let sessionStore = SessionStore(
            appStore: makeSnapshotAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        sessionStore.selectedSessionID = sessionID

        return ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.colorScheme, colorScheme)
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
                createdAt: snapshotMessageDate
            ),
            fallbackSessionID: sessionID
        )

        let sessionStore = SessionStore(
            appStore: makeSnapshotAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        sessionStore.selectedSessionID = sessionID

        return ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.colorScheme, .light)
            .frame(width: 1024, height: 768)
    }

    private func makeMixedActivityConversation() async -> some View {
        let sessionID = "snapshot_mixed_activity"
        let turnID = "turn_mixed_activity"
        let conversationStore = ConversationStore()
        let themeStore = makeThemeStore()
        let landscapeImage = snapshotImageDataURL(size: CGSize(width: 420, height: 210), accent: .systemPurple)
        let portraitImage = snapshotImageDataURL(size: CGSize(width: 240, height: 360), accent: .systemOrange)
        // 生产视图仍通过 `.task(id:)` 异步解码；快照先填充同一缓存，确保捕获的是稳定完成态。
        _ = await DataURLImageDecoder.image(
            from: landscapeImage,
            cacheKey: ConversationImageSource.markdown(landscapeImage).id,
            maxPixelSize: 1_600
        )
        _ = await DataURLImageDecoder.image(
            from: portraitImage,
            cacheKey: ConversationImageSource.markdown(portraitImage).id,
            maxPixelSize: 1_600
        )
        let history = [
            CodexHistoryMessage(
                id: "mixed-user",
                role: "user",
                content: "请检查这两张 iPad 截图 [图片] [图片]",
                turnPayload: CodexAppServerTurnPayload(input: [
                    .text("请检查这两张 iPad 截图"),
                    .image(url: landscapeImage),
                    .image(url: portraitImage)
                ]),
                createdAt: snapshotMessageDate,
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "mixed-reasoning",
                role: "system",
                kind: .reasoningSummary,
                content: "先核对输入框和过程时间线的层级。",
                activityPayload: ConversationActivityPayload(
                    category: .thinking,
                    displayTitle: "推理摘要",
                    subtitle: "先核对输入框和过程时间线的层级。"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(1),
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "mixed-read",
                role: "system",
                kind: .commandSummary,
                content: "命令：sed -n 1,180p ConversationView.swift",
                activityPayload: ConversationActivityPayload(
                    category: .runCommand,
                    displayTitle: "查看 ConversationView.swift",
                    status: "completed",
                    command: "sed -n 1,180p ConversationView.swift"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(2),
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "mixed-search",
                role: "system",
                kind: .commandSummary,
                content: "命令：rg ProcessedTurnRow",
                activityPayload: ConversationActivityPayload(
                    category: .runCommand,
                    displayTitle: "搜索 ProcessedTurnRow",
                    status: "completed",
                    command: "rg ProcessedTurnRow"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(3),
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "mixed-build",
                role: "system",
                kind: .commandSummary,
                content: "命令：xcodebuild test",
                activityPayload: ConversationActivityPayload(
                    category: .runCommand,
                    displayTitle: "运行 xcodebuild test",
                    status: "completed",
                    command: "xcodebuild test",
                    cwd: "/Users/me/code/codex-ipad-agent",
                    exitCode: 0,
                    outputPreview: "Testing started\n** TEST SUCCEEDED **"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(4),
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "mixed-diff",
                role: "system",
                kind: .fileChangeSummary,
                content: "文件变更：ConversationView.swift modified",
                activityPayload: ConversationActivityPayload(
                    category: .editFile,
                    displayTitle: "修改 ConversationView.swift",
                    status: "completed",
                    filePaths: ["ios/MimiRemote/Sources/Features/Conversation/ConversationView.swift"]
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(5),
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "mixed-input",
                role: "system",
                kind: .userInput,
                content: "补充信息已提交：固定中文",
                createdAt: snapshotMessageDate.addingTimeInterval(6),
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "mixed-final",
                role: "assistant",
                content: "已按 iPad 高频操作方式整理完成。",
                createdAt: snapshotMessageDate.addingTimeInterval(7),
                turnID: turnID,
                sendStatus: .confirmed
            )
        ]
        conversationStore.setHistory(history, sessionID: sessionID)

        let sessionStore = SessionStore(
            appStore: makeSnapshotAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        sessionStore.selectedSessionID = sessionID

        return ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.colorScheme, .light)
            .frame(width: 1024, height: 900)
    }

    private func makeUnavailableUserImageGallery() -> some View {
        let sessionID = "snapshot_unavailable_user_images"
        let conversationStore = ConversationStore()
        let themeStore = makeThemeStore()
        let unavailableImages = [
            "codex-clipboard-9ba62714-bcfb-4693-805b-1be6e284e924.png",
            "codex-clipboard-fcc85816-9d5f-4ea6-919a-ea89b639a5d9.png",
            "codex-clipboard-15031bdc-111a-4669-b3e6-4ef5f2094829.png",
            "codex-clipboard-f64f3119-46f6-479a-b93d-abc5d81f879f.png"
        ]
        let imageInput = unavailableImages.map { CodexAppServerUserInput.image(url: $0) }

        conversationStore.setHistory([
            CodexHistoryMessage(
                id: "unavailable-images-user",
                role: "user",
                content: "请评估这四张封面",
                turnPayload: CodexAppServerTurnPayload(
                    input: [.text("请评估这四张封面")] + imageInput
                ),
                createdAt: snapshotMessageDate,
                turnID: "turn_unavailable_images",
                sendStatus: .confirmed
            )
        ], sessionID: sessionID)

        let sessionStore = SessionStore(
            appStore: makeSnapshotAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        sessionStore.selectedSessionID = sessionID

        return ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.colorScheme, .light)
            .frame(width: 1024, height: 900)
    }

    private func makeExpandedProcessGroup() -> some View {
        let themeStore = makeThemeStore()
        let turnID = "snapshot-process-group"
        let reasoning = ConversationMessage(
            stableID: "snapshot-process-reasoning",
            turnID: turnID,
            role: .system,
            kind: .reasoningSummary,
            content: "Planning backend migration testing with Docker",
            createdAt: snapshotMessageDate,
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .thinking,
                displayTitle: "推理摘要",
                subtitle: "Planning backend migration testing with Docker"
            )
        )
        let command = ConversationMessage(
            stableID: "snapshot-process-command",
            turnID: turnID,
            role: .system,
            kind: .commandSummary,
            content: "命令：docker compose run --rm api go test ./...",
            createdAt: snapshotMessageDate.addingTimeInterval(1),
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "运行后端迁移测试",
                status: "completed",
                command: "docker compose run --rm api go test ./...",
                cwd: "/Users/me/code/chat-archive",
                exitCode: 0
            )
        )
        let file = ConversationMessage(
            stableID: "snapshot-process-file",
            turnID: turnID,
            role: .system,
            kind: .fileChangeSummary,
            content: "文件变更：internal/config/config_test.go modified",
            createdAt: snapshotMessageDate.addingTimeInterval(2),
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .editFile,
                displayTitle: "修改 config_test.go",
                status: "completed",
                filePaths: ["internal/config/config_test.go"]
            )
        )
        let group = ConversationProcessGroup(
            id: "snapshot-process-group",
            turnID: turnID,
            header: reasoning,
            activities: [command, file],
            status: .completed
        )
        let layout = ConversationLayout(containerWidth: 820, horizontalSizeClass: .regular)

        return VStack {
            ConversationProcessGroupRow(
                group: group,
                layout: layout,
                isExpanded: true,
                expandedActivityIDs: [],
                toggleGroup: {},
                toggleActivity: { _ in }
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .environmentObject(themeStore)
            .environment(\.colorScheme, .light)
        .background(themeStore.tokens(for: .light).background)
        .frame(width: 820, height: 260)
    }

    private func makeCommentaryAndTrailingProcessConversation() -> some View {
        let sessionID = "snapshot-commentary"
        let turnID = "turn-commentary"
        let conversationStore = ConversationStore()
        let themeStore = makeThemeStore()
        conversationStore.setHistory([
            CodexHistoryMessage(
                id: "commentary-user",
                role: "user",
                content: "继续排查企微原文查看失败。",
                createdAt: snapshotMessageDate,
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "commentary-old-reasoning",
                role: "system",
                kind: .reasoningSummary,
                content: "Inspecting login chain",
                activityPayload: ConversationActivityPayload(
                    category: .thinking,
                    displayTitle: "推理摘要",
                    subtitle: "Inspecting login chain"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(1),
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "commentary-old-command",
                role: "system",
                kind: .commandSummary,
                content: "命令：检查线上请求",
                activityPayload: ConversationActivityPayload(
                    category: .runCommand,
                    displayTitle: "检查线上请求",
                    status: "completed"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(2),
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "commentary-visible",
                role: "assistant",
                kind: .commentary,
                content: """
                链路已经进一步确认：主站扫码登录和原文 ticket 都是 `200`，真正失败发生在凭证解密阶段。

                - 统一登录 Cookie 已生效
                - 生产 RSA 私钥文件不存在

                我会继续只读检查备份位置，不修改线上配置。
                """,
                createdAt: snapshotMessageDate.addingTimeInterval(3),
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "commentary-trailing-reasoning-old",
                role: "system",
                kind: .reasoningSummary,
                content: "Searching workspace for private keys",
                activityPayload: ConversationActivityPayload(
                    category: .thinking,
                    displayTitle: "推理摘要",
                    subtitle: "Searching workspace for private keys",
                    status: "inProgress"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(4),
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "commentary-trailing-command",
                role: "system",
                kind: .commandSummary,
                content: "命令：find /opt/chat-archive -name '*.pem'",
                activityPayload: ConversationActivityPayload(
                    category: .runCommand,
                    displayTitle: "搜索私钥备份",
                    status: "running"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(5),
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "commentary-trailing-reasoning-latest",
                role: "system",
                kind: .reasoningSummary,
                content: "Planning credential recovery checks",
                activityPayload: ConversationActivityPayload(
                    category: .thinking,
                    displayTitle: "推理摘要",
                    subtitle: "Planning credential recovery checks",
                    status: "inProgress"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(6),
                turnID: turnID,
                sendStatus: .confirmed
            )
        ], sessionID: sessionID)

        let sessionStore = SessionStore(
            appStore: makeSnapshotAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        sessionStore.selectedSessionID = sessionID

        return ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.colorScheme, .light)
            .frame(width: 430, height: 900)
    }

    func testConversationBubbleAlignment() {
        assertSnapshot(
            of: makeSeededConversation(),
            as: .image(precision: 0.98, layout: .fixed(width: 1024, height: 768))
        )
    }

    func testDefaultDarkConversationPalette() {
        assertSnapshot(
            of: makeSeededConversation(colorScheme: .dark),
            as: .image(precision: 0.98, layout: .fixed(width: 1024, height: 768))
        )
    }

    func testRichMarkdownConversationRendering() {
        assertSnapshot(
            of: makeRichMarkdownConversation(),
            as: .image(precision: 0.98, layout: .fixed(width: 1024, height: 768))
        )
    }

    func testMixedActivityAndImageConversationRendering() async {
        let view = await makeMixedActivityConversation()

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 1024, height: 900))
        )
    }

    func testUnavailableUserImageGalleryRemainsLegibleInLightTheme() {
        assertSnapshot(
            of: makeUnavailableUserImageGallery(),
            as: .image(precision: 0.98, layout: .fixed(width: 1024, height: 900))
        )
    }

    func testExpandedProcessGroupRendering() {
        assertSnapshot(
            of: makeExpandedProcessGroup(),
            as: .image(precision: 0.98, layout: .fixed(width: 820, height: 260))
        )
    }

    func testCommentaryAndTrailingProcessRendering() {
        assertSnapshot(
            of: makeCommentaryAndTrailingProcessConversation(),
            as: .image(precision: 0.98, layout: .fixed(width: 430, height: 900))
        )
    }

    func testEmptyConversationState() {
        let conversationStore = ConversationStore()
        let themeStore = makeThemeStore()
        let sessionStore = SessionStore(
            appStore: makeSnapshotAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        // 未选中会话 → 空状态占位。
        let view = ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.colorScheme, .light)
            .frame(width: 1024, height: 768)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 1024, height: 768))
        )
    }

    func testConversationLayoutUsesVisibleIPadSplitViewWidth() {
        // iPad mini 横屏中 NavigationSplitView 可能把 1133pt 整窗宽度交给 detail，
        // 同时以 300pt leading safe area 表达侧栏；composer 必须只消费剩余的 833pt。
        let layout = ConversationLayout(
            containerWidth: 1133,
            horizontalSizeClass: .regular,
            safeAreaInsets: EdgeInsets(top: 0, leading: 300, bottom: 0, trailing: 0)
        )

        XCTAssertEqual(layout.horizontalInset, 24)
        XCTAssertEqual(layout.composerAvailableWidth, 785)
        XCTAssertEqual(layout.composerMaxWidth, 785)
        XCTAssertFalse(
            ConversationLayout.usesCompactComposerMetrics(
                availableWidth: layout.composerMaxWidth,
                horizontalSizeClass: .regular
            ),
            "regular size class 的 iPad 分栏使用标准输入指标"
        )
        XCTAssertLessThanOrEqual(
            layout.composerMaxWidth + layout.horizontalInset * 2,
            833,
            "输入卡和目标栏不能超过实际 detail 列宽"
        )
    }

    func testConversationLayoutKeepsIPadMiniComposerInsideConversationTrack() {
        let layout = ConversationLayout(
            containerWidth: 744,
            horizontalSizeClass: .regular
        )

        XCTAssertEqual(layout.horizontalInset, 16)
        XCTAssertEqual(layout.composerAvailableWidth, 712)
        XCTAssertEqual(layout.composerMaxWidth, 712)
        XCTAssertEqual(layout.composerMaxWidth + layout.horizontalInset * 2, 744)
        XCTAssertFalse(
            ConversationLayout.usesCompactComposerMetrics(
                availableWidth: layout.composerMaxWidth,
                horizontalSizeClass: .regular
            ),
            "iPad mini 竖屏仍使用标准输入尺寸"
        )
    }

    func testConversationLayoutUsesStandardMetricsForMeasuredLandscapeDetailTrack() {
        // 真机横屏：1133pt 整窗减去约 300pt 侧栏后，内容测量宽度约 832pt。
        // 布局直接采用测量值，不再做 safe area 减法，因此不会重复扣除侧栏
        // 被误算成 528pt 而落入紧凑分支、隐藏快捷行开关。
        let layout = ConversationLayout(
            containerWidth: 832,
            horizontalSizeClass: .regular
        )

        XCTAssertFalse(
            ConversationLayout.usesCompactComposerMetrics(
                availableWidth: min(layout.composerAvailableWidth, layout.composerMaxWidth),
                horizontalSizeClass: .regular
            ),
            "横屏 detail 列必须使用标准输入指标"
        )
    }

    func testConversationLayoutUsesCompactMetricsOnPhone() {
        XCTAssertTrue(
            ConversationLayout.usesCompactComposerMetrics(
                availableWidth: 390,
                horizontalSizeClass: .compact
            ),
            "手机端继续使用紧凑指标"
        )
    }

    func testConversationLayoutFallsBackToWidthWithoutSizeClass() {
        XCTAssertTrue(
            ConversationLayout.usesCompactComposerMetrics(
                availableWidth: 390,
                horizontalSizeClass: nil
            )
        )
        XCTAssertFalse(
            ConversationLayout.usesCompactComposerMetrics(
                availableWidth: 744,
                horizontalSizeClass: nil
            )
        )
    }

    func testConversationLayoutForcesCompactMetricsInExtremelyNarrowRegularSplit() {
        XCTAssertTrue(
            ConversationLayout.usesCompactComposerMetrics(
                availableWidth: 520,
                horizontalSizeClass: .regular
            )
        )
    }

    func testComposerStatusTrayCrowdedState() async {
        let view = await makeComposerStatusTrayCrowdedView(width: 1024, height: 768)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 1024, height: 768))
        )
    }

    func testComposerStatusTrayIPadMiniPortraitWidth() async {
        let view = await makeComposerStatusTrayCrowdedView(width: 744, height: 1133)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 744, height: 1133))
        )
    }

    func testComposerStatusTrayIPadMiniLandscapeDetailWidth() async {
        // 横屏回归：1133pt 整窗减去约 300pt 侧栏后，detail 列约 832pt。
        // Composer 按内容测量宽度必须用标准指标（快捷行、按钮文字标签都在），
        // 不允许被 safe area 提案算术把宽度算小而退化成紧凑布局。
        // NavigationSplitView 在快照宿主中的列宽提案与真机不一致，无法直接包装；
        // 这里固定为真实 detail 列宽，真机横屏行为仍需设备验收。
        let view = await makeComposerStatusTrayCrowdedView(width: 832, height: 744)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 832, height: 744))
        )
    }

    func testComposerStatusTrayCrowdedCompactWidth() async {
        let view = await makeComposerStatusTrayCrowdedView(width: 420, height: 768)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 420, height: 768))
        )
    }

    func testComposerStatusTrayExpandedCrowdedState() async {
        let view = await makeComposerStatusTrayCrowdedView(width: 420, height: 768, goalExpanded: true)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 420, height: 768))
        )
    }

    func testComposerStatusTrayExpandedWideState() async {
        // iPad 宽屏展开态必须继续和输入卡共用整条 composer 轨道，防止状态栏退回旧的 680pt 上限。
        let view = await makeComposerStatusTrayCrowdedView(width: 1024, height: 768, goalExpanded: true)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 1024, height: 768))
        )
    }

    private func makeComposerStatusTrayCrowdedView(width: CGFloat, height: CGFloat, goalExpanded: Bool = false) async -> some View {
        let project = AgentProject(id: "tray-project", name: "tray-project", path: "/Users/me/code/tray-project")
        let sessionID = "crowded"
        let threadID = "thread-\(sessionID)"
        let goal = ThreadGoal(
            threadID: threadID,
            objective: "你是 Mimi Remote 的多 Agent 产品研发团队主控，需要把目标、接管和额度状态压缩到输入框上方。",
            status: .active,
            tokenBudget: 12_000_000,
            tokensUsed: 10_200_000,
            timeUsedSeconds: 25_740,
            createdAt: snapshotMessageDate,
            updatedAt: snapshotMessageDate
        )
        let session = makeSnapshotSession(
            id: sessionID,
            project: project,
            title: "Composer 状态托盘",
            status: "running",
            preview: "验证接管、额度和目标同时出现时的底部 composer 布局。",
            activeTurnID: "turn-crowded",
            rateLimit: RateLimitSummary(limitName: "Codex", primaryUsedPercent: 85, primaryResetsAt: 1_782_883_260),
            goal: goal
        )
        let conversationStore = ConversationStore()
        conversationStore.applyAssistantDelta(
            AgentDelta(
                text: "这条消息用于把 composer 推到真实会话底部；状态托盘应该保持紧凑，不要把输入框挤出首屏。",
                role: .assistant,
                kind: .message
            ),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: "turn-crowded",
                itemID: "item-crowded",
                messageID: nil,
                clientMessageID: nil,
                revision: 1,
                createdAt: snapshotMessageDate
            ),
            fallbackSessionID: sessionID
        )
        let themeStore = makeThemeStore()
        let appStore = makeSnapshotAppStore()
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project, lastOpenedAt: Date(timeIntervalSince1970: 10))],
                endpoint: appStore.endpoint
            ),
            clientFactory: {
                SnapshotSessionAPIClient(projects: [project], sessions: [session])
            }
        )
        await sessionStore.refreshAll(autoAttach: false)
        await sessionStore.toggleProjectExpansion(project)
        sessionStore.selectedSessionID = sessionID

        let composerDefaultsSuite = "ConversationSnapshotTests.Composer.\(UUID().uuidString)"
        let composerDefaults = UserDefaults(suiteName: composerDefaultsSuite)!
        composerDefaults.removePersistentDomain(forName: composerDefaultsSuite)
        composerDefaults.set(true, forKey: "composer.shortcuts.expanded")

        return ConversationView(initialGoalStatusExpanded: goalExpanded)
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            // 快照固定为浅色，避免运行测试前手动切过模拟器外观就整组误报。
            .environment(\.colorScheme, .light)
            .defaultAppStorage(composerDefaults)
            .frame(width: width, height: height)
    }

    func testProjectSessionDashboard() async {
        let project = AgentProject(id: "mimi-remote", name: "mimi-remote", path: "/Users/me/code/mimi-remote")
        let themeStore = makeThemeStore()
        let appStore = makeSnapshotAppStore()
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
                preview: "只加载最近消息，向上滚动时再按 cursor 补旧内容。",
                runtimeProvider: "claude"
            ),
            makeSnapshotSession(
                id: "done",
                project: project,
                title: "README 迁移说明",
                status: "completed",
                preview: "记录 Tailscale、Token 和 app-server 本机监听。"
            )
        ]
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project, lastOpenedAt: Date(timeIntervalSince1970: 10))],
                endpoint: appStore.endpoint
            ),
            clientFactory: {
                SnapshotSessionAPIClient(projects: [project], sessions: sessions)
            }
        )
        await sessionStore.refreshAll(autoAttach: false)
        await sessionStore.toggleProjectExpansion(project)

        let view = NavigationStack {
            ProjectSidebarView(showsSessions: true)
                .toolbar(.hidden, for: .navigationBar)
        }
        .environmentObject(sessionStore)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .frame(width: 420, height: 768)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 420, height: 768))
        )
    }

    func testSessionRuntimeBadgesInConversationList() {
        let project = AgentProject(id: "runtime-badges", name: "runtime-badges", path: "/Users/me/code/runtime-badges")
        let themeStore = makeThemeStore()
        let codex = makeSnapshotSession(
            id: "runtime-codex",
            project: project,
            title: "优化会话列表",
            status: "completed",
            preview: "Codex 会话"
        )
        let claude = makeSnapshotSession(
            id: "runtime-claude",
            project: project,
            title: "检查兼容性",
            status: "completed",
            preview: "Claude Code 会话",
            runtimeProvider: "claude"
        )

        let view = VStack(spacing: 8) {
            SessionIndexRow(
                session: codex,
                foregroundActivity: nil,
                isSelected: true,
                isPinned: false,
                isArchived: false,
                reminder: nil,
                isObserving: false,
                style: .library
            )
            SessionIndexRow(
                session: claude,
                foregroundActivity: nil,
                isSelected: false,
                isPinned: false,
                isArchived: false,
                reminder: nil,
                isObserving: false,
                style: .library
            )
        }
        .padding(16)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .background(themeStore.tokens(for: .light).background)
        .frame(width: 460, height: 190)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 460, height: 190))
        )
    }

    func testUnifiedWorkbenchSidebarNavigationChrome() {
        let themeStore = makeThemeStore()
        let tokens = themeStore.tokens(for: .light)

        let view = VStack(spacing: 0) {
            List {
                Section {
                    WorkbenchSidebarDestinationButton(
                        title: "会话",
                        systemImage: "bubble.left.and.bubble.right",
                        isSelected: true,
                        tokens: tokens,
                        action: {}
                    )
                    WorkbenchSidebarDestinationButton(
                        title: "工作区",
                        systemImage: "folder",
                        isSelected: false,
                        tokens: tokens,
                        action: {}
                    )
                }

                Section("最近") {
                    Text("优化侧栏创建入口")
                        .font(themeStore.uiFont(.subheadline, weight: .medium))
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)

            // 直接渲染生产组件，避免 NavigationSplitView 在测试宿主中自动折叠侧栏。
            WorkbenchSidebarFooter(tokens: tokens, onOpenSettings: {}, onNewSession: {})
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .background(tokens.sidebarBackground)
        .frame(width: 340, height: 768)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 340, height: 768))
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

    private func snapshotImageDataURL(size: CGSize, accent: UIColor) -> String {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            accent.withAlphaComponent(0.16).setFill()
            context.fill(CGRect(x: 12, y: 12, width: size.width - 24, height: size.height - 24))
            accent.setStroke()
            context.cgContext.setLineWidth(6)
            context.cgContext.stroke(CGRect(x: 24, y: 24, width: size.width - 48, height: size.height - 48))
        }
        let data = image.pngData() ?? Data()
        return "data:image/png;base64,\(data.base64EncodedString())"
    }

    /// 快照不能读取模拟器里真实配对过的 Mac；隔离偏好与 Keychain 后，composer 的默认状态才可复现。
    private func makeSnapshotAppStore() -> AppStore {
        let suiteName = "ConversationSnapshotTests.AppStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppStore(defaults: defaults, tokenStore: TokenStore(keychain: TestKeychainOperations()))
    }

    private func makeRecentWorkspaceStore(workspaces: [AgentWorkspace], endpoint: String) -> RecentWorkspaceStore {
        let suiteName = "ConversationSnapshotTests.RecentWorkspaces.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = RecentWorkspaceStore(defaults: defaults)
        store.save(workspaces, endpoint: endpoint)
        return store
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
        pendingApproval: ApprovalSummary? = nil,
        goal: ThreadGoal? = nil,
        runtimeProvider: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: title,
            status: status,
            source: "codex",
            runtimeProvider: runtimeProvider,
            resumeID: "thread-\(id)",
            createdAt: nil,
            updatedAt: nil,
            preview: preview,
            activeTurnID: activeTurnID,
            lastSeq: 42,
            revision: 3,
            usage: usage,
            rateLimit: rateLimit,
            pendingApproval: pendingApproval,
            goal: goal
        )
    }
}

@MainActor
final class PendingUserInputSheetSnapshotTests: XCTestCase {
    func testLongMultiSelectFormKeepsBottomActionsVisibleOnIPhone() {
        let options = (1...6).map { index in
            AgentUserInputOption(
                label: "选项 \(index)",
                description: "这是用于验证小屏长表单滚动与文字换行的说明。"
            )
        }
        let questions = (1...5).map { index in
            AgentUserInputQuestion(
                id: "question-\(index)",
                header: "问题 \(index)",
                question: "请选择这一组里所有需要继续执行的优化项。",
                isOther: index == 5,
                isSecret: false,
                options: options,
                multiSelect: true
            )
        }
        let request = AgentUserInputRequest(
            id: "snapshot-request",
            threadID: "snapshot-thread",
            turnID: "snapshot-turn",
            itemID: "snapshot-item",
            questions: questions
        )
        let suiteName = "PendingUserInputSheetSnapshotTests.Theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let themeStore = ThemeStore(defaults: defaults)
        let view = PendingUserInputSheet(
            presentation: PendingUserInputPresentation(request: request),
            isSubmitting: false,
            draft: .constant(PendingUserInputDraft()),
            onSubmit: { _ in true }
        )
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .frame(width: 390, height: 844)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 390, height: 844))
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
}
