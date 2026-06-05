import SwiftUI
import UIKit

struct ConversationView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let model = ConversationScreenModel(
            selectedSession: sessionStore.selectedSession,
            selectedProject: sessionStore.selectedProject,
            foregroundActivity: sessionStore.selectedForegroundActivity,
            errorMessage: sessionStore.errorMessage
        )

        GeometryReader { proxy in
            let layout = ConversationLayout(containerWidth: proxy.size.width, horizontalSizeClass: horizontalSizeClass)

            VStack(spacing: 0) {
                topStatusStrip(model: model, layout: layout)
                ConversationTimelineView(layout: layout)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Spacer(minLength: 0)
                    ComposerView()
                        .frame(maxWidth: layout.composerMaxWidth)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, layout.horizontalInset)
                .padding(.top, layout.composerTopPadding)
                .padding(.bottom, layout.composerBottomPadding)
                .background(tokens.surface.opacity(0.94))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(tokens.border)
                        .frame(height: 1)
                }
            }
            .background(tokens.background.ignoresSafeArea())
        }
    }

    @ViewBuilder
    private func topStatusStrip(model: ConversationScreenModel, layout: ConversationLayout) -> some View {
        if model.errorMessage != nil || model.foregroundActivity != nil {
            HStack {
                Spacer(minLength: 0)
                foregroundStatus(model: model)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, layout.horizontalInset)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func foregroundStatus(model: ConversationScreenModel) -> some View {
        if let message = model.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(themeStore.uiFont(.caption, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(statusChipBackground)
                .clipShape(Capsule())
        } else if let activity = model.foregroundActivity {
            HStack(spacing: 7) {
                if activity.showsSpinner {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.green)
                } else {
                    Circle()
                        .fill(.green)
                        .frame(width: 7, height: 7)
                }
                Text(activity.title)
            }
            .font(themeStore.uiFont(.caption, weight: .medium))
            .foregroundStyle(workbenchSecondaryText)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(statusChipBackground)
                .clipShape(Capsule())
        }
    }

    private var statusChipBackground: Color {
        themeStore.tokens(for: colorScheme).elevatedSurface
    }

    private var workbenchSecondaryText: Color {
        themeStore.tokens(for: colorScheme).secondaryText
    }
}

struct ConversationScreenModel: Equatable {
    let sessionID: SessionID?
    let title: String
    let subtitle: String
    let foregroundActivity: SessionForegroundActivity?
    let errorMessage: String?

    init(
        selectedSession: AgentSession?,
        selectedProject: AgentProject?,
        foregroundActivity: SessionForegroundActivity?,
        errorMessage: String?
    ) {
        self.sessionID = selectedSession?.id
        self.title = selectedSession?.title ?? selectedProject?.name ?? "会话"
        self.subtitle = selectedSession?.dir ?? selectedProject?.path ?? ""
        self.foregroundActivity = foregroundActivity
        self.errorMessage = errorMessage
    }
}

struct ConversationLayout: Equatable {
    let horizontalInset: CGFloat
    let messageSideSpacer: CGFloat
    let composerMaxWidth: CGFloat
    let composerTopPadding: CGFloat
    let composerBottomPadding: CGFloat
    let userBubbleMaxWidth: CGFloat
    let assistantBubbleMaxWidth: CGFloat
    let systemMaxWidth: CGFloat
    let runtimeCardMaxWidth: CGFloat
    let emptyStateMaxWidth: CGFloat

    var messageRowInsets: EdgeInsets {
        EdgeInsets(top: 7, leading: horizontalInset, bottom: 7, trailing: horizontalInset)
    }

    init(containerWidth: CGFloat, horizontalSizeClass: UserInterfaceSizeClass?) {
        let isCompactWidth = horizontalSizeClass == .compact || containerWidth < 560
        let isTightPadWidth = containerWidth < 820

        horizontalInset = isCompactWidth ? 12 : (isTightPadWidth ? 16 : 24)
        messageSideSpacer = isCompactWidth ? 12 : (isTightPadWidth ? 24 : 56)
        composerMaxWidth = isCompactWidth ? .infinity : min(920, max(360, containerWidth - horizontalInset * 2))
        composerTopPadding = isCompactWidth ? 8 : 10
        composerBottomPadding = isCompactWidth ? 10 : 12

        // 气泡宽度按实际容器收缩，保留左右身份感，同时避免 iPhone/mini 竖屏横向溢出。
        let rowAvailableWidth = max(240, containerWidth - horizontalInset * 2 - messageSideSpacer)
        userBubbleMaxWidth = min(isCompactWidth ? 420 : 560, rowAvailableWidth)
        assistantBubbleMaxWidth = min(isCompactWidth ? 520 : 660, rowAvailableWidth)
        systemMaxWidth = min(520, max(240, containerWidth - horizontalInset * 2))
        runtimeCardMaxWidth = min(560, max(260, containerWidth - horizontalInset * 2))
        emptyStateMaxWidth = min(420, max(260, containerWidth - horizontalInset * 2))
    }
}

struct ConversationTimelineView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var conversationStore: ConversationStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let layout: ConversationLayout
    @State private var shouldFollowMessageTail = true
    @State private var forceNextMessageTailScroll = true
    @State private var hasUnseenTailMessage = false
    @State private var isPreservingHistoryScroll = false

    private let messageTailFollowThreshold: CGFloat = 120

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let messages = conversationStore.messages(for: sessionStore.selectedSessionID)
        return ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                // 用 List（底层 UITableView）替代 ScrollView + LazyVStack：行高是真实测量值、
                // 有 cell 复用，scrollTo 对尚未实例化的行也可靠。这样既消除首屏/切换会话
                // “空白要手滑一下”的竞态，右侧滚动条也不再因 LazyVStack 高度估算而长度/位置乱跳。
                List {
                    if messages.isEmpty {
                        emptyState
                            .padding(.top, 80)
                            .frame(maxWidth: .infinity)
                            .listRowSeparator(.hidden)
                            .listRowInsets(layout.messageRowInsets)
                            .listRowBackground(Color.clear)
                    } else {
                        if sessionStore.canLoadEarlierHistory(sessionID: sessionStore.selectedSessionID) {
                            loadEarlierRow(proxy: proxy)
                                .listRowSeparator(.hidden)
                                .listRowInsets(layout.messageRowInsets)
                                .listRowBackground(Color.clear)
                        }
                        ForEach(messages) { message in
                            // .equatable() 让流式输出时只重绘内容变化的那一行，其余行直接复用，
                            // 长对话下 ForEach 的 diff 成本降到只看可见行的值比较。
                            MessageRow(message: message, themeVersion: themeStore.themeVersion, layout: layout)
                                .equatable()
                                .id(message.id)
                                .listRowSeparator(.hidden)
                                .listRowInsets(layout.messageRowInsets)
                                .listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(tokens.background)
                // 是否贴近底部用滚动几何实时判断，只在贴底时跟随流式输出，
                // 用户上翻历史时不会被尾部更新甩回底部。
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    isNearBottom(geometry)
                } action: { _, nearBottom in
                    shouldFollowMessageTail = nearBottom
                    if nearBottom {
                        hasUnseenTailMessage = false
                    }
                }

                if hasUnseenTailMessage {
                    Button {
                        hasUnseenTailMessage = false
                        shouldFollowMessageTail = true
                        scrollToMessageTail(messages: messages, proxy: proxy, animated: true)
                    } label: {
                        Label("新消息", systemImage: "arrow.down.circle.fill")
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tokens.accent)
                    .controlSize(.small)
                    .padding(.trailing, layout.horizontalInset)
                    .padding(.bottom, 18)
                    .accessibilityLabel("回到底部查看新消息")
                }
            }
            .onChange(of: sessionStore.selectedSessionID) { _, _ in
                shouldFollowMessageTail = true
                forceNextMessageTailScroll = true
                hasUnseenTailMessage = false
                isPreservingHistoryScroll = false
            }
            .onChange(of: messages.last?.id) { _, newID in
                guard let newID else {
                    return
                }
                if forceNextMessageTailScroll {
                    // 首屏/切换会话：List 拿到首页数据后无动画贴底，并在下一拍补一次，
                    // 覆盖首次布局时机，确保落在真正的底部而不是空白区。
                    forceNextMessageTailScroll = false
                    hasUnseenTailMessage = false
                    shouldFollowMessageTail = true
                    proxy.scrollTo(newID, anchor: .bottom)
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(newID, anchor: .bottom)
                    }
                    return
                }
                scrollToMessageTail(messages: messages, proxy: proxy, animated: true)
            }
            .onChange(of: messages.last?.renderFingerprint) { _, _ in
                // 流式增量会高频改写最后一条内容；无动画直接定位，跟随输出但不卡。
                scrollToMessageTail(messages: messages, proxy: proxy, animated: false)
            }
        }
    }

    private func loadEarlierRow(proxy: ScrollViewProxy) -> some View {
        HStack {
            Spacer()
            Button {
                let sessionID = sessionStore.selectedSessionID
                // prepend 后把原来最早的一条滚回顶部，保住用户当前阅读位置。
                let anchorID = conversationStore.messages(for: sessionID).first?.id
                Task { @MainActor in
                    await loadEarlierHistory(preserving: anchorID, sessionID: sessionID, proxy: proxy)
                }
            } label: {
                if sessionStore.isLoadingEarlierHistory(sessionID: sessionStore.selectedSessionID) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(workbenchSecondaryText)
                } else {
                    Label("加载更早消息", systemImage: "clock.arrow.circlepath")
                }
            }
            .font(themeStore.uiFont(.caption, weight: .medium))
            .buttonStyle(.borderless)
            .foregroundStyle(workbenchSecondaryText)
            .disabled(sessionStore.isLoadingEarlierHistory(sessionID: sessionStore.selectedSessionID))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(statusChipBackground, in: Capsule())
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func isNearBottom(_ geometry: ScrollGeometry) -> Bool {
        // 距底部多远用滚动几何直接算，不依赖某个具体行是否还被实例化。
        let distanceFromBottom = geometry.contentSize.height - geometry.visibleRect.maxY
        return distanceFromBottom <= messageTailFollowThreshold
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "message")
                .font(themeStore.uiFont(.title2))
                .foregroundStyle(workbenchSecondaryText)
            Text("还没有对话")
                .font(themeStore.uiFont(.headline, weight: .semibold))
                .foregroundStyle(workbenchPrimaryText)
            Text("选择历史会话会加载 Codex 上下文；输入任务会启动或继续当前会话。")
                .font(themeStore.uiFont(.callout))
                .foregroundStyle(workbenchSecondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: layout.emptyStateMaxWidth)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private var statusChipBackground: Color {
        themeStore.tokens(for: colorScheme).elevatedSurface
    }

    private var workbenchPrimaryText: Color {
        themeStore.tokens(for: colorScheme).primaryText
    }

    private var workbenchSecondaryText: Color {
        themeStore.tokens(for: colorScheme).secondaryText
    }

    private func scrollToMessageTail(messages: [ConversationMessage], proxy: ScrollViewProxy, animated: Bool) {
        guard let lastID = messages.last?.id else {
            return
        }
        guard !isPreservingHistoryScroll else {
            return
        }
        guard shouldFollowMessageTail || forceNextMessageTailScroll else {
            hasUnseenTailMessage = true
            return
        }
        hasUnseenTailMessage = false
        forceNextMessageTailScroll = false
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }

    @MainActor
    private func loadEarlierHistory(
        preserving anchorID: UUID?,
        sessionID: SessionID?,
        proxy: ScrollViewProxy
    ) async {
        guard !isPreservingHistoryScroll else {
            return
        }
        // 加载更早是向上 prepend，期间屏蔽尾部跟随，避免阅读位置被打断。
        isPreservingHistoryScroll = true
        shouldFollowMessageTail = false
        forceNextMessageTailScroll = false
        hasUnseenTailMessage = false
        defer { isPreservingHistoryScroll = false }

        await sessionStore.loadEarlierHistoryForSelectedSession()
        guard sessionStore.selectedSessionID == sessionID, let anchorID else {
            return
        }
        await Task.yield()
        restoreHistoryAnchor(anchorID, proxy: proxy)
    }

    private func restoreHistoryAnchor(_ anchorID: UUID, proxy: ScrollViewProxy) {
        let messages = conversationStore.messages(for: sessionStore.selectedSessionID)
        guard messages.contains(where: { $0.id == anchorID }) else {
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }
}

private struct MessageRow: View, Equatable {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationMessage
    let themeVersion: Int
    let layout: ConversationLayout

    // 只有内容 fingerprint / 状态变化时才重绘；长消息内容本身不参与这里的逐行比较。
    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.role == rhs.message.role
            && lhs.message.kind == rhs.message.kind
            && lhs.message.sendStatus == rhs.message.sendStatus
            && lhs.message.revision == rhs.message.revision
            && lhs.message.renderFingerprint == rhs.message.renderFingerprint
            && lhs.themeVersion == rhs.themeVersion
            && lhs.layout == rhs.layout
    }

    var body: some View {
        Group {
            switch message.role {
            case .user:
                userRow
            case .assistant:
                assistantRow
            case .system:
                systemRow
            }
        }
        .frame(maxWidth: .infinity, alignment: rowAlignment)
        .contextMenu {
            Button {
                UIPasteboard.general.string = message.content
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }

            if message.role == .user && message.sendStatus == .failed {
                Button {
                    Task { await sessionStore.retryFailedUserMessage(message) }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
            }

            if message.role == .assistant && message.sendStatus == .sending {
                Button(role: .destructive) {
                    sessionStore.sendCtrlC()
                } label: {
                    Label("停止", systemImage: "stop.circle")
                }
            }
        }
    }

    private var userRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: layout.messageSideSpacer)
            VStack(alignment: .trailing, spacing: 3) {
                MessageBubble(message: message, layout: layout)
                statusCaption
            }
        }
    }

    private var assistantRow: some View {
        HStack(spacing: 0) {
            MessageBubble(message: message, layout: layout)
            Spacer(minLength: layout.messageSideSpacer)
        }
    }

    private var systemRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if message.kind == .message {
                SystemNotice(text: message.content, layout: layout)
            } else {
                RuntimeSummaryCard(message: message, layout: layout)
            }
            Spacer(minLength: 0)
        }
    }

    // 状态以气泡下方的小字呈现（贴右），比浮在一旁的图标更直观，也避开了气泡定宽框的定位问题。
    @ViewBuilder
    private var statusCaption: some View {
        switch message.sendStatus {
        case .failed:
            Text("发送失败")
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(.red)
        case .sending:
            Text("发送中…")
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
        default:
            EmptyView()
        }
    }

    private var rowAlignment: Alignment {
        switch message.role {
        case .user:
            return .trailing
        case .assistant:
            return .leading
        case .system:
            return .center
        }
    }
}

private struct MessageBubble: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationMessage
    let layout: ConversationLayout

    var body: some View {
        renderContent
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: maxBubbleWidth, alignment: bubbleAlignment)
            .opacity(message.sendStatus == .sending ? 0.72 : 1)
    }

    @ViewBuilder
    private var renderContent: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let style = MarkdownStyle.make(
            role: message.role,
            colorScheme: colorScheme,
            fontScale: themeStore.fontScale,
            tokens: tokens
        )
        if shouldRenderMarkdown {
            let plan = MessageRenderPlanCache.shared.plan(for: message)
            if plan.isSinglePlainParagraph, case let .paragraph(inline) = plan.blocks.first?.kind {
                Text(inline.plain)
                    .font(style.bodyFont)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: style.blockSpacing) {
                    ForEach(plan.blocks) { block in
                        MarkdownBlockView(block: block, style: style)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(message.content)
                .font(themeStore.uiFont(.body))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shouldRenderMarkdown: Bool {
        message.role == .assistant && message.kind == .message
    }

    private var bubbleAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var maxBubbleWidth: CGFloat {
        message.role == .user ? layout.userBubbleMaxWidth : layout.assistantBubbleMaxWidth
    }

    private var background: Color {
        let tokens = themeStore.tokens(for: colorScheme)
        switch message.role {
        case .user:
            return tokens.userBubble
        default:
            return tokens.assistantBubble
        }
    }

    private var foreground: Color {
        themeStore.tokens(for: colorScheme).primaryText
    }
}

private struct SystemNotice: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let layout: ConversationLayout

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Text(text)
            .font(themeStore.uiFont(.caption))
            .foregroundStyle(tokens.secondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tokens.systemBubble, in: Capsule())
            .frame(maxWidth: layout.systemMaxWidth)
    }
}

private struct RuntimeSummaryCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationMessage
    let layout: ConversationLayout

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbolName)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(message.content)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: layout.runtimeCardMaxWidth, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        }
    }

    private var title: String {
        switch message.kind {
        case .reasoningSummary:
            return "推理摘要"
        case .commandSummary:
            return "命令"
        case .fileChangeSummary:
            return "文件变更"
        case .approval:
            if isApprovedApproval {
                return "审批已批准"
            }
            if isDeclinedApproval {
                return "审批已拒绝"
            }
            return "等待审批"
        case .error:
            return "运行异常"
        case .message:
            return "状态"
        }
    }

    private var symbolName: String {
        switch message.kind {
        case .reasoningSummary:
            return "brain.head.profile"
        case .commandSummary:
            return "terminal"
        case .fileChangeSummary:
            return "doc.text.magnifyingglass"
        case .approval:
            if isApprovedApproval {
                return "checkmark.circle"
            }
            if isDeclinedApproval {
                return "xmark.circle"
            }
            return "exclamationmark.shield"
        case .error:
            return "exclamationmark.triangle"
        case .message:
            return "info.circle"
        }
    }

    private var tint: Color {
        switch message.kind {
        case .approval:
            if isApprovedApproval {
                return .green
            }
            if isDeclinedApproval {
                return .red
            }
            return tokens.warning
        case .error:
            return .red
        case .fileChangeSummary:
            return tokens.accent
        default:
            return tokens.secondaryText
        }
    }

    private var background: Color {
        switch message.kind {
        case .approval:
            if isApprovedApproval {
                return Color.green.opacity(0.10)
            }
            if isDeclinedApproval {
                return Color.red.opacity(0.10)
            }
            return tokens.warning.opacity(0.12)
        case .error:
            return Color.red.opacity(0.10)
        case .fileChangeSummary:
            return tokens.accent.opacity(0.10)
        default:
            return tokens.systemBubble
        }
    }

    private var isApprovedApproval: Bool {
        message.content.hasPrefix("审批已批准") || message.content.hasPrefix("已批准")
    }

    private var isDeclinedApproval: Bool {
        message.content.hasPrefix("审批已拒绝") || message.content.hasPrefix("已拒绝")
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }
}
