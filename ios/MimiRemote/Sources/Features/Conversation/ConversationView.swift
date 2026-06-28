import SwiftUI
import UIKit
import QuickLook

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
        if model.errorMessage != nil || model.statusDisplay != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    statusStripContent(model: model)
                    Spacer(minLength: 0)
                }
                VStack(spacing: 8) {
                    statusStripContent(model: model)
                }
            }
            .padding(.horizontal, layout.horizontalInset)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func statusStripContent(model: ConversationScreenModel) -> some View {
        let status = model.statusDisplay
        let message = model.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)

        if status != nil || message?.isEmpty == false {
            HStack(spacing: 8) {
                if let status {
                    statusChip(status)
                }
                if let message, !message.isEmpty {
                    Label("错误：\(message)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(themeStore.uiFont(.caption, weight: .medium))
                        .lineLimit(2)
                        .minimumScaleFactor(0.86)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(statusChipBackground)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private func statusChip(_ status: AgentSessionDisplayStatus) -> some View {
        HStack(spacing: 7) {
            if status.showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint(for: status.tone))
            } else {
                Image(systemName: status.systemImage)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
            }
            Text("当前：\(status.title)")
        }
        .font(themeStore.uiFont(.caption, weight: .medium))
        .foregroundStyle(tint(for: status.tone))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(statusChipBackground)
        .clipShape(Capsule())
    }

    private func tint(for tone: AgentSessionStatusTone) -> Color {
        switch tone {
        case .active:
            return .green
        case .warning:
            return .orange
        case .danger:
            return .red
        case .complete:
            return .blue
        case .neutral:
            return workbenchSecondaryText
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
    let statusDisplay: AgentSessionDisplayStatus?
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
        self.statusDisplay = Self.visibleStatusDisplay(for: selectedSession, foregroundActivity: foregroundActivity)
        self.errorMessage = errorMessage
    }

    private static func visibleStatusDisplay(
        for session: AgentSession?,
        foregroundActivity: SessionForegroundActivity?
    ) -> AgentSessionDisplayStatus? {
        guard let session else {
            return nil
        }
        guard session.isRunning ||
            foregroundActivity != nil ||
            session.pendingApproval != nil ||
            session.status == SessionStatus.failed.rawValue ||
            session.status == SessionStatus.waitingForInput.rawValue ||
            session.status == SessionStatus.waitingForApproval.rawValue
        else {
            return nil
        }
        return session.displayStatus(foregroundActivity: foregroundActivity)
    }
}

enum ConversationTimelineItem: Identifiable, Equatable {
    case message(ConversationMessage)
    case processed(ProcessedConversationGroup)

    var id: String {
        switch self {
        case .message(let message):
            return "message:\(message.id.uuidString)"
        case .processed(let group):
            return group.id
        }
    }
}

struct ProcessedConversationGroup: Identifiable, Equatable {
    let id: String
    let messages: [ConversationMessage]
    let startedAt: Date
    let completedAt: Date

    var duration: TimeInterval {
        max(0, completedAt.timeIntervalSince(startedAt))
    }

    var title: String {
        let durationText = Self.compactDuration(duration)
        return "已处理 \(messages.count) 步 · \(durationText)"
    }

    private static func compactDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes > 0 {
            return "\(minutes)m \(remainingSeconds)s"
        }
        return "\(remainingSeconds)s"
    }
}

struct ConversationTimelineItemBuilder {
    static func items(from messages: [ConversationMessage]) -> [ConversationTimelineItem] {
        let completedAssistantByTurnID = completedAssistantMessagesByTurnID(in: messages)
        let processMessagesByTurnID = groupedProcessMessagesByTurnID(
            in: messages,
            completedTurnIDs: Set(completedAssistantByTurnID.keys)
        )
        let groupedProcessMessageIDs = Set(processMessagesByTurnID.values.flatMap { grouped in
            grouped.map(\.id)
        })
        var insertedProcessTurnIDs = Set<TurnID>()
        var items: [ConversationTimelineItem] = []
        var index = messages.startIndex

        while index < messages.endIndex {
            let message = messages[index]
            if groupedProcessMessageIDs.contains(message.id) {
                index = messages.index(after: index)
                continue
            }
            if let turnID = message.turnID,
               isCompletedAssistantMessage(message),
               let processMessages = processMessagesByTurnID[turnID],
               !insertedProcessTurnIDs.contains(turnID) {
                // app-server 事件可能先到最终 assistant、后到 diff/approval；渲染层按 turnID 归位，
                // 保持“已处理”入口在最终回答之前，避免过程卡散落在最终回答之后。
                items.append(.processed(group(from: processMessages, completedBy: message, id: "processed:turn:\(turnID)")))
                insertedProcessTurnIDs.insert(turnID)
            }
            guard isCollapsibleProcessMessage(message) else {
                items.append(.message(message))
                index = messages.index(after: index)
                continue
            }

            let startIndex = index
            var processMessages: [ConversationMessage] = []
            while index < messages.endIndex, isCollapsibleProcessMessage(messages[index]) {
                processMessages.append(messages[index])
                index = messages.index(after: index)
            }

            if let completedAssistant = fallbackCompletedAssistant(for: processMessages, nextIndex: index, messages: messages) {
                // 只有最终 assistant 回复已经落定时才折叠过程；运行中仍完整展示，避免隐藏实时状态。
                items.append(.processed(group(from: processMessages, completedBy: completedAssistant)))
            } else {
                items.append(contentsOf: messages[startIndex..<index].map(ConversationTimelineItem.message))
            }
        }

        return items
    }

    private static func isCollapsibleProcessMessage(_ message: ConversationMessage) -> Bool {
        guard message.role == .system else {
            return false
        }
        switch message.kind {
        case .reasoningSummary, .commandSummary, .fileChangeSummary, .approval:
            return true
        case .error, .message:
            return false
        }
    }

    private static func isCompletedAssistantMessage(_ message: ConversationMessage) -> Bool {
        guard message.role == .assistant && message.kind == .message else {
            return false
        }
        return message.sendStatus == .confirmed || message.sendStatus == .sent
    }

    private static func completedAssistantMessagesByTurnID(in messages: [ConversationMessage]) -> [TurnID: ConversationMessage] {
        var result: [TurnID: ConversationMessage] = [:]
        for message in messages {
            guard let turnID = message.turnID, !turnID.isEmpty, isCompletedAssistantMessage(message) else {
                continue
            }
            result[turnID] = result[turnID] ?? message
        }
        return result
    }

    private static func groupedProcessMessagesByTurnID(
        in messages: [ConversationMessage],
        completedTurnIDs: Set<TurnID>
    ) -> [TurnID: [ConversationMessage]] {
        var result: [TurnID: [ConversationMessage]] = [:]
        for message in messages {
            guard let turnID = message.turnID,
                  completedTurnIDs.contains(turnID),
                  isCollapsibleProcessMessage(message)
            else {
                continue
            }
            result[turnID, default: []].append(message)
        }
        return result
    }

    private static func fallbackCompletedAssistant(
        for processMessages: [ConversationMessage],
        nextIndex: [ConversationMessage].Index,
        messages: [ConversationMessage]
    ) -> ConversationMessage? {
        guard sharedTurnID(in: processMessages) == nil else {
            return nil
        }
        guard let next = messages[safe: nextIndex], isCompletedAssistantMessage(next) else {
            return nil
        }
        return next
    }

    private static func sharedTurnID(in messages: [ConversationMessage]) -> TurnID? {
        let turnIDs = Set(messages.compactMap(\.turnID))
        guard turnIDs.count == 1, let turnID = turnIDs.first, !turnID.isEmpty else {
            return nil
        }
        return turnID
    }

    private static func group(
        from messages: [ConversationMessage],
        completedBy assistant: ConversationMessage,
        id: String? = nil
    ) -> ProcessedConversationGroup {
        let firstID = messages.first?.id.uuidString ?? assistant.id.uuidString
        let lastID = messages.last?.id.uuidString ?? firstID
        let processStart = messages.map(\.createdAt).min() ?? assistant.createdAt
        let processEnd = messages.map(\.createdAt).max() ?? assistant.createdAt
        let startedAt = min(processStart, assistant.createdAt)
        let completedAt = max(processEnd, assistant.createdAt)
        return ProcessedConversationGroup(
            id: id ?? "processed:\(firstID):\(lastID)",
            messages: messages,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
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
    @State private var expandedProcessedGroupIDs: Set<String> = []

    private let messageTailFollowThreshold: CGFloat = 120

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let messages = conversationStore.messages(for: sessionStore.selectedSessionID)
        let timelineItems = ConversationTimelineItemBuilder.items(from: messages)
        let timelineItemIDs = timelineItems.map(\.id)
        return ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                // 用 List（底层 UITableView）替代 ScrollView + LazyVStack：行高是真实测量值、
                // 有 cell 复用，scrollTo 对尚未实例化的行也可靠。这样既消除首屏/切换会话
                // “空白要手滑一下”的竞态，右侧滚动条也不再因 LazyVStack 高度估算而长度/位置乱跳。
                List {
                    if timelineItems.isEmpty {
                        emptyState
                            .padding(.top, 80)
                            .frame(maxWidth: .infinity)
                            .listRowSeparator(.hidden)
                            .listRowInsets(layout.messageRowInsets)
                            .listRowBackground(Color.clear)
                    } else {
                        if sessionStore.canLoadEarlierHistory(sessionID: sessionStore.selectedSessionID) {
                            loadEarlierRow(proxy: proxy, timelineItems: timelineItems)
                                .listRowSeparator(.hidden)
                                .listRowInsets(layout.messageRowInsets)
                                .listRowBackground(Color.clear)
                        }
                        ForEach(timelineItems) { item in
                            // .equatable() 让流式输出时只重绘内容变化的那一行，其余行直接复用，
                            // 长对话下 ForEach 的 diff 成本降到只看可见行的值比较。
                            timelineRow(item)
                                .id(item.id)
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
                        scrollToTimelineTail(timelineItems: timelineItems, proxy: proxy, animated: true)
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
                expandedProcessedGroupIDs.removeAll()
            }
            .onChange(of: messages.last?.id) { _, newID in
                guard newID != nil else {
                    return
                }
                if forceNextMessageTailScroll {
                    // 首屏/切换会话：List 拿到首页数据后无动画贴底，并在下一拍补一次，
                    // 覆盖首次布局时机，确保落在真正的底部而不是空白区。
                    forceNextMessageTailScroll = false
                    hasUnseenTailMessage = false
                    shouldFollowMessageTail = true
                    scrollToTimelineTail(timelineItems: timelineItems, proxy: proxy, animated: false)
                    Task { @MainActor in
                        await Task.yield()
                        scrollToTimelineTail(timelineItems: timelineItems, proxy: proxy, animated: false)
                    }
                    return
                }
                scrollToTimelineTail(timelineItems: timelineItems, proxy: proxy, animated: true)
            }
            .onChange(of: messages.last?.renderFingerprint) { _, _ in
                // 流式增量会高频改写最后一条内容；无动画直接定位，跟随输出但不卡。
                scrollToTimelineTail(timelineItems: timelineItems, proxy: proxy, animated: false)
            }
            .onChange(of: timelineItemIDs) { _, _ in
                // turn 完成可能只改变 sendStatus，却让过程卡从多行收成“已处理”一行；
                // 监听派生 row id，确保折叠发生时底部跟随逻辑仍然有机会重锚。
                scrollToTimelineTail(timelineItems: timelineItems, proxy: proxy, animated: false)
            }
        }
    }

    @ViewBuilder
    private func timelineRow(_ item: ConversationTimelineItem) -> some View {
        switch item {
        case .message(let message):
            MessageRow(message: message, themeVersion: themeStore.themeVersion, layout: layout)
                .equatable()
        case .processed(let group):
            ProcessedTurnRow(
                group: group,
                layout: layout,
                isExpanded: expandedProcessedGroupIDs.contains(group.id),
                toggle: {
                    if expandedProcessedGroupIDs.contains(group.id) {
                        expandedProcessedGroupIDs.remove(group.id)
                    } else {
                        expandedProcessedGroupIDs.insert(group.id)
                    }
                }
            )
        }
    }

    private func loadEarlierRow(proxy: ScrollViewProxy, timelineItems: [ConversationTimelineItem]) -> some View {
        HStack {
            Spacer()
            Button {
                let sessionID = sessionStore.selectedSessionID
                // prepend 后把原来最早的一条滚回顶部，保住用户当前阅读位置。
                let anchorID = timelineItems.first?.id
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
            Text("选择历史会话会加载上下文；输入任务会启动或继续当前会话。")
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

    private func scrollToTimelineTail(timelineItems: [ConversationTimelineItem], proxy: ScrollViewProxy, animated: Bool) {
        guard let lastID = timelineItems.last?.id else {
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
        preserving anchorID: String?,
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

    private func restoreHistoryAnchor(_ anchorID: String, proxy: ScrollViewProxy) {
        let messages = conversationStore.messages(for: sessionStore.selectedSessionID)
        let timelineItems = ConversationTimelineItemBuilder.items(from: messages)
        guard timelineItems.contains(where: { $0.id == anchorID }) else {
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }
}

private struct ProcessedTurnRow: View, Equatable {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let group: ProcessedConversationGroup
    let layout: ConversationLayout
    let isExpanded: Bool
    let toggle: () -> Void
    private static let disclosureAnimation = Animation.easeInOut(duration: 0.18)

    static func == (lhs: ProcessedTurnRow, rhs: ProcessedTurnRow) -> Bool {
        lhs.group == rhs.group && lhs.layout == rhs.layout && lhs.isExpanded == rhs.isExpanded
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                        Text(group.title)
                            .font(themeStore.uiFont(.caption, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(themeStore.uiFont(.caption2, weight: .semibold))
                            .frame(width: 10, height: 10)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(Self.disclosureAnimation, value: isExpanded)
                    }
                    .foregroundStyle(tokens.secondaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "收起已处理过程" : "展开已处理过程")

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(group.messages) { message in
                            RuntimeSummaryCard(message: message, layout: layout)
                        }
                    }
                    .padding(.top, 8)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: layout.assistantBubbleMaxWidth, alignment: .leading)
            .animation(Self.disclosureAnimation, value: isExpanded)

            Spacer(minLength: layout.messageSideSpacer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
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
            && lhs.message.createdAt == rhs.message.createdAt
            && lhs.message.updatedAt == rhs.message.updatedAt
            && lhs.message.renderFingerprint == rhs.message.renderFingerprint
            && lhs.message.turnPayload == rhs.message.turnPayload
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
        Group {
            if isCenteredSystemNotice {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    SystemNotice(message: message, layout: layout)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 0) {
                    RuntimeSummaryCard(message: message, layout: layout)
                    Spacer(minLength: layout.messageSideSpacer)
                }
            }
        }
    }

    private var isCenteredSystemNotice: Bool {
        message.kind == .message
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
            return isCenteredSystemNotice ? .center : .leading
        }
    }
}

private struct MessageBubble: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationMessage
    let layout: ConversationLayout
    @State private var previewURL: URL?
    @State private var previewingPath: String?
    @State private var previewError: String?

    var body: some View {
        contentWithTimestamp
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: maxBubbleWidth, alignment: bubbleAlignment)
            .opacity(message.sendStatus == .sending ? 0.72 : 1)
            .quickLookPreview($previewURL)
    }

    private var contentWithTimestamp: some View {
        ZStack(alignment: .bottomTrailing) {
            renderContent
                .padding(.bottom, 16)
            MessageTimestampCaption(text: message.timestampCaptionText)
        }
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
        if shouldRenderUserImages {
            userImageContent(style: style)
        } else if shouldRenderMarkdown {
            let plan = MessageRenderPlanCache.shared.plan(for: message)
            let references = fileReferences
            if references.isEmpty {
                markdownContent(plan: plan, style: style)
            } else {
                VStack(alignment: .leading, spacing: style.blockSpacing) {
                    markdownContent(plan: plan, style: style)
                    FileReferencePreviewStrip(
                        references: references,
                        previewingPath: previewingPath,
                        previewError: previewError,
                        onPreview: { reference in
                            Task { await preview(reference) }
                        }
                    )
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

    private func userImageContent(style: MarkdownStyle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let text = userImageText
            if !text.isEmpty {
                Text(text)
                    .font(style.bodyFont)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(payloadImageItems) { item in
                if let source = ConversationImageSource.input(item) {
                    ConversationImagePreview(
                        source: source,
                        title: nil,
                        style: style,
                        maxHeight: 240,
                        showsCaption: false
                    )
                }
            }

            if payloadImageItems.isEmpty {
                ForEach(contentImageReferences) { reference in
                    ConversationImagePreview(
                        source: .localPath(reference.path),
                        title: nil,
                        style: style,
                        maxHeight: 240,
                        showsCaption: false
                    )
                }
            }

            let accessoryText = payloadAccessoryText
            if !accessoryText.isEmpty {
                Text(accessoryText)
                    .font(style.captionFont)
                    .foregroundStyle(style.secondaryColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func markdownContent(plan: MessageRenderPlan, style: MarkdownStyle) -> some View {
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
    }

    private var shouldRenderMarkdown: Bool {
        message.role == .assistant && message.kind == .message
    }

    private var shouldRenderUserImages: Bool {
        message.role == .user
            && message.kind == .message
            && (!payloadImageItems.isEmpty || !contentImageReferences.isEmpty)
    }

    private var payloadImageItems: [CodexAppServerUserInput] {
        guard let payload = message.turnPayload else {
            return []
        }
        return payload.input.filter { ConversationImageSource.input($0) != nil }
    }

    private var contentImageReferences: [ConversationFileReference] {
        guard message.turnPayload == nil || payloadImageItems.isEmpty else {
            return []
        }
        return ConversationFileReferenceDetector.imageReferences(in: message.content)
    }

    private var userImageText: String {
        if !payloadImageItems.isEmpty {
            return payloadText
        }
        return contentTextWithoutImagePaths
    }

    private var payloadText: String {
        guard let payload = message.turnPayload else {
            return ""
        }
        return payload.input.compactMap { item in
            if case .text(let text, _) = item {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private var contentTextWithoutImagePaths: String {
        var text = message.content
        for reference in contentImageReferences {
            let fileURL = URL(fileURLWithPath: reference.path).absoluteString
            let variants = [
                reference.path,
                reference.path.replacingOccurrences(of: " ", with: "\\ "),
                fileURL,
                fileURL.removingPercentEncoding ?? fileURL,
                "[图片 \(reference.name)]",
                "[图片]"
            ]
            for variant in variants where !variant.isEmpty {
                text = text.replacingOccurrences(of: variant, with: "")
            }
        }
        text = strippedUserFileMentionPrompt(from: text)
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "：:，,。.；;"))
    }

    private func strippedUserFileMentionPrompt(from text: String) -> String {
        for marker in ["## My request for Codex:", "## My request for Codex："] {
            if let range = text.range(of: marker, options: [.caseInsensitive]) {
                return String(text[range.upperBound...])
            }
        }
        return text
    }

    private var payloadAccessoryText: String {
        guard let payload = message.turnPayload else {
            return ""
        }
        return payload.input.compactMap { item in
            switch item {
            case .skill, .mention:
                return item.previewText
            case .text, .image, .localImage:
                return nil
            }
        }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var fileReferences: [ConversationFileReference] {
        guard shouldRenderMarkdown, message.sendStatus != .sending else {
            return []
        }
        return ConversationFileReferenceDetector.references(in: message.content)
    }

    private func preview(_ reference: ConversationFileReference) async {
        previewingPath = reference.path
        previewError = nil
        defer {
            if previewingPath == reference.path {
                previewingPath = nil
            }
        }
        do {
            previewURL = try await sessionStore.previewFile(path: reference.path)
        } catch {
            previewError = userFacingPreviewError(error)
        }
    }

    private func userFacingPreviewError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 || status == 405 {
            return "当前 agentd 版本还不支持文件预览，请升级 agentd。"
        }
        if case AgentAPIError.server(let status, _) = error, status == 403 {
            return "该文件不在授权范围内或不可访问。"
        }
        if case AgentAPIError.server(let status, _) = error, status == 413 {
            return "文件过大，暂不支持预览。"
        }
        return error.localizedDescription
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

private struct FileReferencePreviewStrip: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let references: [ConversationFileReference]
    let previewingPath: String?
    let previewError: String?
    let onPreview: (ConversationFileReference) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 6) {
            ForEach(references) { reference in
                Button {
                    onPreview(reference)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.viewfinder")
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                            .foregroundStyle(tokens.accent)
                            .frame(width: 18, height: 18)
                        Text(reference.name)
                            .font(themeStore.uiFont(.caption, weight: .medium))
                            .foregroundStyle(tokens.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if previewingPath == reference.path {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(tokens.border, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(previewingPath != nil)
                .accessibilityLabel("预览 \(reference.name)")
            }

            if let previewError {
                Text(previewError)
                    .font(themeStore.uiFont(.caption2))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SystemNotice: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationMessage
    let layout: ConversationLayout

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        ZStack(alignment: .bottomTrailing) {
            Text(message.content)
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            MessageTimestampCaption(text: message.timestampCaptionText)
        }
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
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    MessageTimestampCaption(text: message.timestampCaptionText)
                }
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

private struct MessageTimestampCaption: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let text: String

    var body: some View {
        Text(text)
            .font(themeStore.uiFont(.caption2, weight: .medium))
            .foregroundStyle(themeStore.tokens(for: colorScheme).tertiaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.88)
            .accessibilityLabel("消息时间 \(text)")
    }
}

private extension ConversationMessage {
    var timestampCaptionText: String {
        switch role {
        case .user:
            return "发出 \(Self.compactTime(createdAt))"
        case .assistant:
            guard sendStatus != .sending else {
                return "开始 \(Self.compactTime(createdAt))"
            }
            let completedAt = updatedAt ?? createdAt
            let started = Self.compactTime(createdAt)
            let completed = Self.compactTime(completedAt)
            // 同一分钟内开始和完成显示相同时间时，只保留完成时间，减少气泡右下角噪音。
            if started == completed {
                return "完成 \(completed)"
            }
            return "开始 \(started) · 完成 \(completed)"
        case .system:
            if let updatedAt, Self.compactTime(updatedAt) != Self.compactTime(createdAt) {
                return "\(Self.compactTime(createdAt)) · \(Self.compactTime(updatedAt))"
            }
            return Self.compactTime(createdAt)
        }
    }

    private static func compactTime(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }
}
