import SwiftUI
import UIKit

struct ConversationView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    var body: some View {
        let model = ConversationScreenModel(
            selectedSession: sessionStore.selectedSession,
            selectedProject: sessionStore.selectedProject,
            foregroundActivity: sessionStore.selectedForegroundActivity,
            errorMessage: sessionStore.errorMessage
        )

        VStack(spacing: 0) {
            topStatusStrip(model: model)
            ConversationTimelineView()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                ComposerView()
                    .frame(maxWidth: 920)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(.regularMaterial)
            .overlay(alignment: .top) {
                Divider()
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    @ViewBuilder
    private func topStatusStrip(model: ConversationScreenModel) -> some View {
        if model.errorMessage != nil || model.foregroundActivity != nil {
            HStack {
                Spacer(minLength: 0)
                foregroundStatus(model: model)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func foregroundStatus(model: ConversationScreenModel) -> some View {
        if let message = model.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption.weight(.medium))
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
            .font(.caption.weight(.medium))
            .foregroundStyle(workbenchSecondaryText)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(statusChipBackground)
                .clipShape(Capsule())
        }
    }

    private var statusChipBackground: Color {
        Color(.secondarySystemBackground)
    }

    private var workbenchSecondaryText: Color {
        .secondary
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

struct ConversationTimelineView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var conversationStore: ConversationStore
    @State private var shouldFollowMessageTail = true
    @State private var forceNextMessageTailScroll = true
    @State private var hasUnseenTailMessage = false

    private let messageTailAnchorID = "conversation-message-tail"
    private let conversationScrollSpace = "conversation-scroll-space"
    private let messageTailFollowThreshold: CGFloat = 120

    var body: some View {
        let messages = conversationStore.messages(for: sessionStore.selectedSessionID)
        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if messages.isEmpty {
                                emptyState
                                    .padding(.top, 80)
                            } else {
                                loadEarlierRow
                                ForEach(messages) { message in
                                    // .equatable() 让流式输出时只重绘内容变化的那一行，其余行直接复用，
                                    // 长对话下 ForEach 的 diff 成本降到只看可见行的值比较。
                                    // 行宽用 maxWidth 自适应，不再依赖 geometry 宽度——否则侧栏收起/展开时
                                    // 容器宽度逐帧变化会让每条可见消息每帧重绘，造成动画卡顿。
                                    MessageRow(message: message)
                                        .equatable()
                                        .id(message.id)
                                }
                                messageTailSentinel
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .coordinateSpace(name: conversationScrollSpace)

                    if hasUnseenTailMessage {
                        Button {
                            hasUnseenTailMessage = false
                            shouldFollowMessageTail = true
                            forceNextMessageTailScroll = true
                            scrollToMessageTail(messages: messages, proxy: proxy, animated: true)
                        } label: {
                            Label("新消息", systemImage: "arrow.down.circle.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.trailing, 24)
                        .padding(.bottom, 18)
                        .accessibilityLabel("回到底部查看新消息")
                    }
                }
                .onPreferenceChange(MessageTailOffsetKey.self) { tailMaxY in
                    // 只在用户还贴近底部时自动跟随流式输出；用户向上阅读历史时不再被 token 更新拉回底部。
                    let isFollowingTail = tailMaxY <= geometry.size.height + messageTailFollowThreshold
                    shouldFollowMessageTail = isFollowingTail
                    if isFollowingTail {
                        hasUnseenTailMessage = false
                    }
                }
                .onChange(of: sessionStore.selectedSessionID) { _, _ in
                    shouldFollowMessageTail = true
                    forceNextMessageTailScroll = true
                    hasUnseenTailMessage = false
                }
                .onChange(of: messages.last?.id) { _, _ in
                    // 只有尾部新消息到达时才滚到底；加载更早历史会 prepend，不应打断阅读位置。
                    scrollToMessageTail(messages: messages, proxy: proxy, animated: true)
                }
                .onChange(of: messages.last?.renderFingerprint) { _, _ in
                    // 流式增量会高频改写最后一条内容；动画滚动会让多段 0.18s 动画互相打架，
                    // 这里改成无动画直接定位，跟随输出但不卡。
                    scrollToMessageTail(messages: messages, proxy: proxy, animated: false)
                }
            }
        }
    }

    private var messageTailSentinel: some View {
        Color.clear
            .frame(height: 1)
            .id(messageTailAnchorID)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MessageTailOffsetKey.self,
                        value: proxy.frame(in: .named(conversationScrollSpace)).maxY
                    )
                }
            }
    }

    @ViewBuilder
    private var loadEarlierRow: some View {
        if sessionStore.canLoadEarlierHistory(sessionID: sessionStore.selectedSessionID) {
            HStack {
                Spacer()
                Button {
                    Task { await sessionStore.loadEarlierHistoryForSelectedSession() }
                } label: {
                    if sessionStore.isLoadingEarlierHistory(sessionID: sessionStore.selectedSessionID) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(workbenchSecondaryText)
                    } else {
                        Label("加载更早消息", systemImage: "clock.arrow.circlepath")
                    }
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.borderless)
                .foregroundStyle(workbenchSecondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(statusChipBackground, in: Capsule())
                Spacer()
            }
            .padding(.bottom, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "message")
                .font(.title2)
                .foregroundStyle(workbenchSecondaryText)
            Text("还没有对话")
                .font(.headline)
                .foregroundStyle(workbenchPrimaryText)
            Text("选择历史会话会加载 Codex 上下文；输入任务会启动或继续当前会话。")
                .font(.callout)
                .foregroundStyle(workbenchSecondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private var statusChipBackground: Color {
        Color(.secondarySystemBackground)
    }

    private var workbenchPrimaryText: Color {
        .primary
    }

    private var workbenchSecondaryText: Color {
        .secondary
    }

    private func scrollToMessageTail(messages: [ConversationMessage], proxy: ScrollViewProxy, animated: Bool) {
        guard !messages.isEmpty else {
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
                proxy.scrollTo(messageTailAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(messageTailAnchorID, anchor: .bottom)
        }
    }
}

private struct MessageTailOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MessageRow: View, Equatable {
    @EnvironmentObject private var sessionStore: SessionStore
    let message: ConversationMessage

    // 只有内容 fingerprint / 状态变化时才重绘；长消息内容本身不参与这里的逐行比较。
    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.role == rhs.message.role
            && lhs.message.kind == rhs.message.kind
            && lhs.message.sendStatus == rhs.message.sendStatus
            && lhs.message.revision == rhs.message.revision
            && lhs.message.renderFingerprint == rhs.message.renderFingerprint
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
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 3) {
                MessageBubble(message: message)
                statusCaption
            }
        }
    }

    private var assistantRow: some View {
        HStack(spacing: 0) {
            MessageBubble(message: message)
            Spacer(minLength: 56)
        }
    }

    private var systemRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if message.kind == .message {
                SystemNotice(text: message.content)
            } else {
                RuntimeSummaryCard(message: message)
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
                .font(.caption2)
                .foregroundStyle(.red)
        case .sending:
            Text("发送中…")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
    let message: ConversationMessage

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
        let plan = MessageRenderPlanCache.shared.plan(for: message)
        if plan.isSinglePlainText {
            Text(plan.segments.first?.text ?? "")
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan.segments) { segment in
                    segmentView(segment)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: MessageRenderSegment) -> some View {
        switch segment.kind {
        case .text:
            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code:
            Text(segment.text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(codeBlockBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var bubbleAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var maxBubbleWidth: CGFloat {
        message.role == .user ? 560 : 660
    }

    private var background: Color {
        switch message.role {
        case .user:
            // 强调气泡用系统强调色，浅色/深色都跟随系统。
            return Color.accentColor
        default:
            // 助手用系统中性面。
            return Color(.secondarySystemBackground)
        }
    }

    private var foreground: Color {
        message.role == .user ? .white : .primary
    }

    private var codeBlockBackground: Color {
        message.role == .user ? Color.white.opacity(0.16) : Color(.tertiarySystemBackground)
    }
}

private struct SystemNotice: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .frame(maxWidth: 520)
    }
}

private struct RuntimeSummaryCard: View {
    let message: ConversationMessage

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(message.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 560, alignment: .leading)
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
            return "checkmark.seal"
        case .error:
            return "exclamationmark.triangle"
        case .message:
            return "info.circle"
        }
    }

    private var tint: Color {
        switch message.kind {
        case .approval:
            return .orange
        case .error:
            return .red
        case .fileChangeSummary:
            return .blue
        default:
            return .secondary
        }
    }

    private var background: Color {
        switch message.kind {
        case .approval:
            return Color.orange.opacity(0.12)
        case .error:
            return Color.red.opacity(0.10)
        case .fileChangeSummary:
            return Color.blue.opacity(0.10)
        default:
            return Color(.secondarySystemBackground)
        }
    }
}
