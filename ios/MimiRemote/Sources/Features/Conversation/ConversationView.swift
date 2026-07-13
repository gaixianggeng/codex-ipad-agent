import SwiftUI
import UIKit
import QuickLook

struct ConversationView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let initialGoalStatusExpanded: Bool

    init(initialGoalStatusExpanded: Bool = false) {
        self.initialGoalStatusExpanded = initialGoalStatusExpanded
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let model = ConversationScreenModel(
            selectedSession: sessionStore.selectedSession,
            selectedProject: sessionStore.selectedProject,
            foregroundActivity: sessionStore.selectedForegroundActivity,
            runtimeActivitySnapshot: sessionStore.selectedRuntimeActivitySnapshot,
            historySavingsNotice: sessionStore.selectedHistorySavingsNotice,
            quotaNotice: sessionStore.selectedQuotaNotice,
            webSocketStatus: sessionStore.webSocketStatus,
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
                    ComposerView(
                        availableWidth: layout.composerAvailableWidth,
                        initialGoalStatusExpanded: initialGoalStatusExpanded
                    )
                        .frame(maxWidth: layout.composerMaxWidth)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, layout.horizontalInset)
                .padding(.top, layout.composerTopPadding)
                .padding(.bottom, layout.composerBottomPadding)
                // 首页依靠暖色底和浮层卡片建立层级；会话页底部沿用同一语义，
                // 去掉旧版整宽白色 dock 与硬分隔线，让输入卡片成为唯一主操作表面。
                .background(tokens.background.opacity(0.97))
            }
            .background(tokens.background.ignoresSafeArea())
        }
    }

    @ViewBuilder
    private func topStatusStrip(model: ConversationScreenModel, layout: ConversationLayout) -> some View {
        if model.errorMessage != nil || model.statusDisplay != nil || model.historySavingsNotice != nil || model.quotaNotice != nil {
            Group {
                if model.runtimeActivitySnapshot != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        statusStripContainer(model: model, now: timeline.date)
                    }
                } else {
                    // 只有运行心跳需要秒级刷新；普通错误/状态条保持静态，减少整页重算。
                    statusStripContainer(model: model, now: Date())
                }
            }
            .padding(.horizontal, layout.horizontalInset)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func statusStripContainer(model: ConversationScreenModel, now: Date) -> some View {
        VStack(spacing: 8) {
            if let notice = model.historySavingsNotice {
                historySavingsBanner(notice)
            }
            if let notice = model.quotaNotice {
                quotaLimitBanner(notice)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    statusStripContent(model: model, now: now, stacksVertically: false)
                    Spacer(minLength: 0)
                }
                statusStripContent(model: model, now: now, stacksVertically: true)
            }
        }
    }

    @ViewBuilder
    private func statusStripContent(model: ConversationScreenModel, now: Date, stacksVertically: Bool) -> some View {
        let status = model.statusDisplay
        let message = model.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let runtimeDisplay = RuntimeActivityDisplay.make(
            snapshot: model.runtimeActivitySnapshot,
            webSocketStatus: model.webSocketStatus,
            now: now
        )

        if status != nil || message?.isEmpty == false {
            if stacksVertically {
                VStack(spacing: 8) {
                    statusStripChips(status: status, message: message, runtimeDisplay: runtimeDisplay)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 8) {
                    statusStripChips(status: status, message: message, runtimeDisplay: runtimeDisplay)
                }
            }
        }
    }

    @ViewBuilder
    private func statusStripChips(
        status: AgentSessionDisplayStatus?,
        message: String?,
        runtimeDisplay: RuntimeActivityDisplay?
    ) -> some View {
        if let status {
            statusChip(status, runtimeDisplay: runtimeDisplay)
        }
        if let message, !message.isEmpty {
            errorChip(message)
        }
    }

    private func errorChip(_ message: String) -> some View {
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

    private func statusChip(_ status: AgentSessionDisplayStatus, runtimeDisplay: RuntimeActivityDisplay?) -> some View {
        let displayTone = runtimeDisplay?.tone ?? status.tone
        return HStack(alignment: .center, spacing: 7) {
            if status.showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint(for: displayTone))
                    .frame(width: 16, height: 16, alignment: .center)
            } else {
                Image(systemName: runtimeDisplay?.systemImage ?? status.systemImage)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .frame(width: 16, height: 16, alignment: .center)
            }
            Text(statusText(status, runtimeDisplay: runtimeDisplay))
        }
        .font(themeStore.uiFont(.caption, weight: .medium))
        .foregroundStyle(tint(for: displayTone))
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(statusChipBackground)
        .clipShape(Capsule())
    }

    private func statusText(_ status: AgentSessionDisplayStatus, runtimeDisplay: RuntimeActivityDisplay?) -> String {
        if let runtimeDisplay {
            return "当前：\(status.title) · \(runtimeDisplay.detailText)"
        }
        return "当前：\(status.title)"
    }

    private func historySavingsBanner(_ notice: HistorySavingsNotice) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                historySavingsBannerMessage(notice)
                Spacer(minLength: 0)
                historySavingsBannerActions(notice)
            }
            VStack(alignment: .leading, spacing: 8) {
                historySavingsBannerMessage(notice)
                historySavingsBannerActions(notice)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.elevatedSurface)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tokens.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func historySavingsBannerMessage(_ notice: HistorySavingsNotice) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(themeStore.uiFont(.body, weight: .semibold))
                .foregroundStyle(tokens.accent)
                .frame(width: 22, height: 22)
            Text(notice.message)
                .font(themeStore.uiFont(.caption, weight: .medium))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func quotaLimitBanner(_ notice: CodexQuotaNotice) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                quotaLimitBannerMessage(notice)
                Spacer(minLength: 0)
                quotaLimitBannerActions(notice)
            }
            VStack(alignment: .leading, spacing: 8) {
                quotaLimitBannerMessage(notice)
                quotaLimitBannerActions(notice)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.warning.opacity(0.12))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tokens.warning.opacity(0.42), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func quotaLimitBannerMessage(_ notice: CodexQuotaNotice) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: "speedometer")
                .font(themeStore.uiFont(.body, weight: .semibold))
                .foregroundStyle(tokens.warning)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(notice.message)
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
            }
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func quotaLimitBannerActions(_ notice: CodexQuotaNotice) -> some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    await sessionStore.refreshCurrentContext()
                }
            } label: {
                Label("刷新状态", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(sessionStore.isRefreshingSelectedSession || sessionStore.isLoading)

            if notice.canDismiss {
                Button {
                    sessionStore.dismissErrorMessage()
                } label: {
                    Label("关闭", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func historySavingsBannerActions(_ notice: HistorySavingsNotice) -> some View {
        HStack(spacing: 8) {
            switch notice.kind {
            case .loadingFull:
                Button {
                    Task {
                        await sessionStore.loadSummaryHistoryForSelectedSession()
                    }
                } label: {
                    Label("只看缩略版", systemImage: "text.justify")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(sessionStore.isRefreshingSelectedSession)

            case .fullFailed:
                Button {
                    Task {
                        await sessionStore.loadFullHistoryForSelectedSession()
                    }
                } label: {
                    Label("重试完整历史", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(sessionStore.isRefreshingSelectedSession)

                Button {
                    Task {
                        await sessionStore.loadSummaryHistoryForSelectedSession()
                    }
                } label: {
                    Label("只看缩略版", systemImage: "text.justify")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(sessionStore.isRefreshingSelectedSession)

            case .loadingSummary:
                Button {} label: {
                    Label("正在加载", systemImage: "hourglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)

            case .summaryLoaded:
                Button {
                    Task {
                        await sessionStore.loadFullHistoryForSelectedSession()
                    }
                } label: {
                    Label("加载完整历史", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(sessionStore.isRefreshingSelectedSession)

                Button {
                    sessionStore.dismissSelectedHistorySavingsNotice()
                } label: {
                    Label("关闭", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

            case .summaryFailed:
                Button {
                    Task {
                        await sessionStore.loadSummaryHistoryForSelectedSession()
                    }
                } label: {
                    Label("重试缩略版", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(sessionStore.isRefreshingSelectedSession)

                Button {
                    sessionStore.dismissSelectedHistorySavingsNotice()
                } label: {
                    Label("关闭", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func tint(for tone: AgentSessionStatusTone) -> Color {
        themeStore.tokens(for: colorScheme).tint(for: tone)
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
    let runtimeActivitySnapshot: RuntimeActivitySnapshot?
    let historySavingsNotice: HistorySavingsNotice?
    let quotaNotice: CodexQuotaNotice?
    let webSocketStatus: WebSocketStatus
    let statusDisplay: AgentSessionDisplayStatus?
    let errorMessage: String?

    init(
        selectedSession: AgentSession?,
        selectedProject: AgentProject?,
        foregroundActivity: SessionForegroundActivity?,
        runtimeActivitySnapshot: RuntimeActivitySnapshot?,
        historySavingsNotice: HistorySavingsNotice?,
        quotaNotice: CodexQuotaNotice?,
        webSocketStatus: WebSocketStatus,
        errorMessage: String?
    ) {
        self.sessionID = selectedSession?.id
        self.title = selectedSession?.title ?? selectedProject?.name ?? "会话"
        self.subtitle = selectedSession?.dir ?? selectedProject?.path ?? ""
        self.foregroundActivity = foregroundActivity
        self.runtimeActivitySnapshot = runtimeActivitySnapshot
        self.historySavingsNotice = historySavingsNotice
        self.quotaNotice = quotaNotice
        self.webSocketStatus = webSocketStatus
        self.statusDisplay = Self.visibleStatusDisplay(for: selectedSession, foregroundActivity: foregroundActivity)
        let trimmedError = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.errorMessage = quotaNotice != nil && trimmedError.map(CodexQuotaNotice.isQuotaError) == true ? nil : errorMessage
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
        let planMessagesByTurnID = planMessagesByTurnID(
            in: messages,
            completedTurnIDs: Set(completedAssistantByTurnID.keys)
        )
        let processMessagesByTurnID = groupedProcessMessagesByTurnID(
            in: messages,
            completedTurnIDs: Set(completedAssistantByTurnID.keys)
        )
        let groupedProcessMessageIDs = Set(processMessagesByTurnID.values.flatMap { grouped in
            grouped.map(\.id)
        })
        let pinnedPlanMessageIDs = Set(planMessagesByTurnID.values.flatMap { grouped in
            grouped.map(\.id)
        })
        var insertedProcessTurnIDs = Set<TurnID>()
        var insertedPlanTurnIDs = Set<TurnID>()
        var items: [ConversationTimelineItem] = []
        var index = messages.startIndex

        while index < messages.endIndex {
            let message = messages[index]
            if groupedProcessMessageIDs.contains(message.id) {
                index = messages.index(after: index)
                continue
            }
            if pinnedPlanMessageIDs.contains(message.id) {
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
                if let turnID = message.turnID,
                   isCompletedAssistantMessage(message),
                   let plans = planMessagesByTurnID[turnID],
                   !insertedPlanTurnIDs.contains(turnID) {
                    items.append(contentsOf: plans.map(ConversationTimelineItem.message))
                    insertedPlanTurnIDs.insert(turnID)
                }
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
        case .reasoningSummary, .commandSummary, .fileChangeSummary, .approval, .userInput:
            return true
        case .plan, .error, .message:
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

    private static func planMessagesByTurnID(
        in messages: [ConversationMessage],
        completedTurnIDs: Set<TurnID>
    ) -> [TurnID: [ConversationMessage]] {
        var result: [TurnID: [ConversationMessage]] = [:]
        for message in messages {
            guard let turnID = message.turnID,
                  completedTurnIDs.contains(turnID),
                  message.role == .system,
                  message.kind == .plan
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
    let composerAvailableWidth: CGFloat
    let composerMaxWidth: CGFloat
    let composerTopPadding: CGFloat
    let composerBottomPadding: CGFloat
    let userBubbleMaxWidth: CGFloat
    let assistantBubbleMaxWidth: CGFloat
    let systemMaxWidth: CGFloat
    let runtimeCardMaxWidth: CGFloat
    let emptyStateMaxWidth: CGFloat

    var messageRowInsets: EdgeInsets {
        EdgeInsets(top: 8, leading: horizontalInset, bottom: 8, trailing: horizontalInset)
    }

    init(containerWidth: CGFloat, horizontalSizeClass: UserInterfaceSizeClass?) {
        let isCompactWidth = horizontalSizeClass == .compact || containerWidth < 560
        let isVeryCompactWidth = containerWidth < 360
        let isTightPadWidth = containerWidth < 820

        // 与会话库 20pt 的卡片轨道接近，同时给 320/344pt 极窄屏保留必要内容宽度。
        horizontalInset = isCompactWidth ? (isVeryCompactWidth ? 12 : 16) : (isTightPadWidth ? 16 : 24)
        messageSideSpacer = isCompactWidth ? 12 : (isTightPadWidth ? 24 : 56)
        composerAvailableWidth = max(240, containerWidth - horizontalInset * 2)
        composerMaxWidth = isCompactWidth ? .infinity : min(920, max(360, composerAvailableWidth))
        composerTopPadding = isCompactWidth ? 10 : 12
        // 底部输入区是触屏主操作区，但 iPad dock 过厚会抢走会话主体重心；保持可点空间，同时减少空闲态压迫感。
        composerBottomPadding = isCompactWidth ? 12 : 16

        // 气泡宽度按实际容器收缩，保留左右身份感，同时避免 iPhone/mini 竖屏横向溢出。
        let rowAvailableWidth = max(240, containerWidth - horizontalInset * 2 - messageSideSpacer)
        userBubbleMaxWidth = min(isCompactWidth ? 420 : 560, rowAvailableWidth)
        let assistantWidthCap: CGFloat = isCompactWidth ? 520 : (isTightPadWidth ? 760 : 840)
        assistantBubbleMaxWidth = min(assistantWidthCap, rowAvailableWidth)
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
    @State private var isTailFollowLockedByLocalSubmit = false
    @State private var isTimelineNearBottom = true
    @State private var hasUnseenTailMessage = false
    @State private var isPreservingHistoryScroll = false
    @State private var expandedProcessedGroupIDs: Set<String> = []
    @State private var timelineItemCache = ConversationTimelineItemCache()
    @State private var timelineScrollPosition = ScrollPosition(edge: .bottom)
    @State private var pendingTailScrollTask: Task<Void, Never>?
    @State private var tailScrollAttemptGeneration = 0
    @State private var userScrollAwayGeneration = 0

    private let messageTailFollowThreshold: CGFloat = 120

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let messages = conversationStore.messages(for: sessionStore.selectedSessionID)
        let timelineItems = timelineItemCache.items(from: messages)
        let timelineItemIDs = timelineItems.map(\.id)
        let tailFollowTaskKey = Self.tailFollowTaskKey(
            sessionID: sessionStore.selectedSessionID,
            tailItemID: timelineItems.last?.id
        )
        let activeUserDeliveryMessageID = Self.activeUserDeliveryMessageID(in: messages)
        let isHistoryLoading = sessionStore.historyLoadProgress(sessionID: sessionStore.selectedSessionID) != nil
        return ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                // 用 List（底层 UITableView）替代 ScrollView + LazyVStack：行高是真实测量值、
                // 有 cell 复用，scrollTo 对尚未实例化的行也可靠。这样既消除首屏/切换会话
                // “空白要手滑一下”的竞态，右侧滚动条也不再因 LazyVStack 高度估算而长度/位置乱跳。
                List {
                    if timelineItems.isEmpty {
                        timelineEmptyState(isHistoryLoading: isHistoryLoading)
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
                            timelineRow(item, activeUserDeliveryMessageID: activeUserDeliveryMessageID)
                                .simultaneousGesture(TapGesture().onEnded {
                                    KeyboardDismissal.dismiss()
                                })
                                .id(item.id)
                                .listRowSeparator(.hidden)
                                .listRowInsets(layout.messageRowInsets)
                                .listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.plain)
                // 每个会话使用独立的 List 身份，避免 UITableView 复用上一个会话的 contentOffset。
                // 新会话挂载时从底部创建，比事后纠正旧滚动位置更稳定。
                .id(sessionStore.selectedSessionID)
                // ScrollPosition 负责持续跟随；首帧和会话切换还会用已校验存在的末行 ID 兜底，
                // 避免 List 只更新绑定、却没有真正提交底层 contentOffset。
                .scrollPosition($timelineScrollPosition)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .background(tokens.background)
                .simultaneousGesture(TapGesture().onEnded {
                    KeyboardDismissal.dismiss()
                })
                .simultaneousGesture(userScrollAwayFromTailGesture)
                // 是否贴近底部用滚动几何实时判断，只在贴底时跟随流式输出，
                // 用户上翻历史时不会被尾部更新甩回底部。
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    isNearBottom(geometry)
                } action: { _, nearBottom in
                    isTimelineNearBottom = nearBottom
                    if nearBottom {
                        shouldFollowMessageTail = true
                        hasUnseenTailMessage = false
                    } else if !isTailFollowLockedByLocalSubmit {
                        shouldFollowMessageTail = false
                    }
                }

                if shouldShowReturnToTailButton(timelineItems: timelineItems) {
                    Button {
                        returnToTimelineTail(timelineItems: timelineItems, proxy: proxy)
                    } label: {
                        returnToTailLabel
                    }
                    // 固定尺寸的纯图标浮层不会因“新消息/回到底部”文案切换而跳宽，
                    // 44pt 点击区也能让它稳定贴在时间线右下角。
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .background(tokens.primaryAction, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    }
                    .contentShape(Circle())
                    .shadow(color: Color.black.opacity(0.16), radius: 6, y: 3)
                    .padding(.trailing, max(layout.horizontalInset, 16))
                    .padding(.bottom, 16)
                    .accessibilityLabel(returnToTailAccessibilityLabel)
                }
            }
            .onChange(of: sessionStore.selectedSessionID) { oldID, newID in
                let shouldPreserveTailFollowLock = isTailFollowLockedByLocalSubmit
                    && Self.isOptimisticSessionID(oldID)
                    && newID != nil
                shouldFollowMessageTail = true
                forceNextMessageTailScroll = true
                isTailFollowLockedByLocalSubmit = shouldPreserveTailFollowLock
                hasUnseenTailMessage = false
                isTimelineNearBottom = true
                isPreservingHistoryScroll = false
                expandedProcessedGroupIDs.removeAll()
                timelineItemCache.removeAll()
                cancelPendingTailScrollAttempts()
                // ScrollPosition 是 View 级状态，不会随 selectedSessionID 自动重建；
                // 切换会话时必须显式丢弃旧位置，并立即为已有缓存消息安排强制贴底。
                timelineScrollPosition = ScrollPosition(edge: .bottom)
                if newID != nil {
                    queueTailScrollAttempts(
                        timelineItems: timelineItems,
                        proxy: proxy,
                        sessionID: newID,
                        expectedTailItemID: timelineItems.last?.id,
                        animatedFirstAttempt: false,
                        force: true
                    )
                }
            }
            .onChange(of: messages.last?.id) { _, newID in
                guard newID != nil else {
                    return
                }
                if Self.shouldForceTailFollow(forNewTailMessage: messages.last) {
                    // 本地发送代表用户明确进入最新上下文；即使滚动几何刚好误判为“不在底部”，
                    // 也要立即贴到尾部，避免发完消息后还停在历史位置。
                    isTailFollowLockedByLocalSubmit = true
                    queueTailScrollAttempts(
                        timelineItems: timelineItems,
                        proxy: proxy,
                        sessionID: sessionStore.selectedSessionID,
                        expectedTailItemID: timelineItems.last?.id,
                        animatedFirstAttempt: true,
                        force: true
                    )
                    return
                }
                if forceNextMessageTailScroll {
                    // 首屏/切换会话：List 拿到首页数据后无动画贴底，并在下一拍补一次，
                    // 覆盖首次布局时机，确保落在真正的底部而不是空白区。
                    queueTailScrollAttempts(
                        timelineItems: timelineItems,
                        proxy: proxy,
                        sessionID: sessionStore.selectedSessionID,
                        expectedTailItemID: timelineItems.last?.id,
                        animatedFirstAttempt: false,
                        force: true
                    )
                    return
                }
                queueTailScrollAttempts(
                    timelineItems: timelineItems,
                    proxy: proxy,
                    sessionID: sessionStore.selectedSessionID,
                    expectedTailItemID: timelineItems.last?.id,
                    animatedFirstAttempt: true,
                    force: false
                )
            }
            .onChange(of: messages.last?.renderFingerprint) { _, _ in
                // 流式增量会高频改写最后一条内容；请求会自动合并，同一更新周期只滚一次。
                queueTailScrollAttempts(
                    timelineItems: timelineItems,
                    proxy: proxy,
                    sessionID: sessionStore.selectedSessionID,
                    expectedTailItemID: timelineItems.last?.id,
                    animatedFirstAttempt: false,
                    force: false,
                    retriesAfterLayout: false
                )
            }
            .onChange(of: timelineItemIDs) { _, _ in
                // turn 完成可能只改变 sendStatus，却让过程卡从多行收成“已处理”一行；
                // 监听派生 row id，确保折叠发生时底部跟随逻辑仍然有机会重锚。
                queueTailScrollAttempts(
                    timelineItems: timelineItems,
                    proxy: proxy,
                    sessionID: sessionStore.selectedSessionID,
                    expectedTailItemID: timelineItems.last?.id,
                    animatedFirstAttempt: false,
                    force: false,
                    retriesAfterLayout: false
                )
            }
            .task(id: tailFollowTaskKey) {
                guard tailFollowTaskKey != nil else {
                    return
                }
                // 进入一个已经有缓存消息的会话时，messages.last 不一定再触发 onChange；
                // 用 task(id:) 补一条首帧重锚路径，避免 List 默认停在最早消息。
                queueTailScrollAttempts(
                    timelineItems: timelineItems,
                    proxy: proxy,
                    sessionID: sessionStore.selectedSessionID,
                    expectedTailItemID: timelineItems.last?.id,
                    animatedFirstAttempt: false,
                    // 首次打开/切换会话不能被尚未稳定的滚动几何拦截；
                    // 后续新消息仍尊重用户主动上翻，不会强行抢回底部。
                    force: forceNextMessageTailScroll
                )
            }
            .onDisappear {
                cancelPendingTailScrollAttempts()
            }
        }
    }

    @ViewBuilder
    private func timelineRow(_ item: ConversationTimelineItem, activeUserDeliveryMessageID: UUID?) -> some View {
        switch item {
        case .message(let message):
            MessageRow(
                message: message,
                themeVersion: themeStore.themeVersion,
                layout: layout,
                showsActiveDeliveryStatus: message.id == activeUserDeliveryMessageID
            )
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

    private static func activeUserDeliveryMessageID(in messages: [ConversationMessage]) -> UUID? {
        // 只把“最新一条还没看到 assistant 回复的用户输入”标成活跃发送态；
        // assistant 气泡一出现，等待文案就收起，避免旧消息长期挂着“等待回复”。
        for message in messages.reversed() {
            if message.role == .assistant && message.kind == .message {
                return nil
            }
            if message.role == .user,
               message.kind == .message,
               message.sendStatus == .sending || message.sendStatus == .sent || message.sendStatus == .failed {
                return message.id
            }
        }
        return nil
    }

    private static func isOptimisticSessionID(_ sessionID: SessionID?) -> Bool {
        sessionID?.hasPrefix("local:") == true
    }

    private var userScrollAwayFromTailGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard value.translation.height > 12 else {
                    return
                }
                // 用户向下拖动列表是在主动回看更早内容；解除本轮发送后的尾部跟随锁。
                isTailFollowLockedByLocalSubmit = false
                shouldFollowMessageTail = false
                userScrollAwayGeneration += 1
                cancelPendingTailScrollAttempts()
            }
    }

    static func shouldForceTailFollow(forNewTailMessage message: ConversationMessage?) -> Bool {
        guard let message else {
            return false
        }
        return message.role == .user
            && message.kind == .message
            && message.clientMessageID != nil
    }

    static func shouldAttemptTailScroll(
        force: Bool,
        shouldFollowMessageTail: Bool,
        forceNextMessageTailScroll: Bool,
        isTailFollowLockedByLocalSubmit: Bool,
        isTimelineNearBottom: Bool
    ) -> Bool {
        force ||
            shouldFollowMessageTail ||
            forceNextMessageTailScroll ||
            isTailFollowLockedByLocalSubmit ||
            isTimelineNearBottom
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

    private func shouldShowReturnToTailButton(timelineItems: [ConversationTimelineItem]) -> Bool {
        !timelineItems.isEmpty && !isPreservingHistoryScroll && (hasUnseenTailMessage || !isTimelineNearBottom)
    }

    private var returnToTailLabel: some View {
        Image(systemName: "arrow.down.to.line")
            .font(themeStore.uiFont(.body, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var returnToTailAccessibilityLabel: String {
        hasUnseenTailMessage ? "回到底部查看新消息" : "回到最新消息"
    }

    private var emptyState: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(themeStore.uiFont(size: 24, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.primaryAction)
                .frame(width: 52, height: 52)
                .background(tokens.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(spacing: 6) {
                Text("开始这次会话")
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(workbenchPrimaryText)
                Text("在下方输入任务，Mimi Remote 会保留当前工作区与会话上下文。")
                    .font(themeStore.uiFont(.callout))
                    .foregroundStyle(workbenchSecondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: layout.emptyStateMaxWidth)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 26)
        .frame(maxWidth: layout.emptyStateMaxWidth)
        .background(tokens.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.58), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(tokens.resolvedScheme == .light ? 0.045 : 0.16), radius: 12, y: 5)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func timelineEmptyState(isHistoryLoading: Bool) -> some View {
        if isHistoryLoading {
            ProgressView("正在加载会话记录")
                .accessibilityLabel("正在加载会话记录")
        } else if let error = sessionStore.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            ContentUnavailableView {
                Label("会话记录加载失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("重试") {
                    Task { await sessionStore.refreshCurrentContext() }
                }
                .buttonStyle(.bordered)
            }
        } else {
            emptyState
        }
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

    private func forceScrollToTimelineTail(
        timelineItems: [ConversationTimelineItem],
        proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let tailItemID = timelineItems.last?.id else {
            return
        }
        guard !isPreservingHistoryScroll else {
            return
        }
        shouldFollowMessageTail = true
        hasUnseenTailMessage = false
        isTimelineNearBottom = true
        forceNextMessageTailScroll = false
        scrollToTimelineTail(tailItemID: tailItemID, proxy: proxy, animated: animated)
    }

    private func queueTailScrollAttempts(
        timelineItems: [ConversationTimelineItem],
        proxy: ScrollViewProxy,
        sessionID: SessionID?,
        expectedTailItemID: String?,
        animatedFirstAttempt: Bool,
        force: Bool,
        retriesAfterLayout: Bool = true
    ) {
        guard let sessionID, let expectedTailItemID, !timelineItems.isEmpty else {
            return
        }
        guard !isPreservingHistoryScroll else {
            return
        }
        guard Self.shouldAttemptTailScroll(
            force: force,
            shouldFollowMessageTail: shouldFollowMessageTail,
            forceNextMessageTailScroll: forceNextMessageTailScroll,
            isTailFollowLockedByLocalSubmit: isTailFollowLockedByLocalSubmit,
            isTimelineNearBottom: isTimelineNearBottom
        ) else {
            hasUnseenTailMessage = true
            return
        }

        // 消息 ID、内容指纹和派生行 ID 可能在同一帧一起变化。先取消旧请求并让出一次
        // MainActor 更新周期，等 List 提交完当前快照后再滚动，避免并发滚动互相覆盖。
        pendingTailScrollTask?.cancel()
        tailScrollAttemptGeneration += 1
        let attemptGeneration = tailScrollAttemptGeneration
        let scrollAwayGeneration = userScrollAwayGeneration
        pendingTailScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  tailScrollAttemptGeneration == attemptGeneration,
                  userScrollAwayGeneration == scrollAwayGeneration,
                  sessionStore.selectedSessionID == sessionID,
                  currentTimelineTailItemID() == expectedTailItemID,
                  !isPreservingHistoryScroll
            else {
                return
            }
            forceScrollToTimelineTail(
                timelineItems: timelineItems,
                proxy: proxy,
                animated: animatedFirstAttempt
            )

            guard retriesAfterLayout else {
                return
            }
            // 首次挂载、Markdown 排版和 List 快照可能分多个布局周期完成。
            // 分两次重锚；用户一旦主动上翻，generation 检查会立刻停止后续滚动。
            for delay in [120_000_000, 320_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled,
                      tailScrollAttemptGeneration == attemptGeneration,
                      userScrollAwayGeneration == scrollAwayGeneration,
                      sessionStore.selectedSessionID == sessionID,
                      currentTimelineTailItemID() == expectedTailItemID,
                      !isPreservingHistoryScroll
                else {
                    return
                }
                forceScrollToTimelineTail(timelineItems: timelineItems, proxy: proxy, animated: false)
            }
        }
    }

    private func cancelPendingTailScrollAttempts() {
        pendingTailScrollTask?.cancel()
        pendingTailScrollTask = nil
        tailScrollAttemptGeneration += 1
    }

    private func returnToTimelineTail(
        timelineItems: [ConversationTimelineItem],
        proxy: ScrollViewProxy
    ) {
        hasUnseenTailMessage = false
        shouldFollowMessageTail = true
        isTailFollowLockedByLocalSubmit = true
        isTimelineNearBottom = true
        queueTailScrollAttempts(
            timelineItems: timelineItems,
            proxy: proxy,
            sessionID: sessionStore.selectedSessionID,
            expectedTailItemID: timelineItems.last?.id,
            animatedFirstAttempt: true,
            force: true,
            retriesAfterLayout: false
        )
    }

    private func scrollToTimelineTail(
        tailItemID: String,
        proxy: ScrollViewProxy,
        animated: Bool
    ) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                timelineScrollPosition.scrollTo(edge: .bottom)
                proxy.scrollTo(tailItemID, anchor: .bottom)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                timelineScrollPosition.scrollTo(edge: .bottom)
                // ScrollPosition 在 List 首帧可能只更新绑定而没有落到底层 contentOffset；
                // 对已验证仍存在的最后一行做显式定位，保证打开会话默认看到最新消息。
                proxy.scrollTo(tailItemID, anchor: .bottom)
            }
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

    private static func tailFollowTaskKey(sessionID: SessionID?, tailItemID: String?) -> String? {
        guard let sessionID, let tailItemID else {
            return nil
        }
        return "\(sessionID):\(tailItemID)"
    }

    private func currentTimelineTailItemID() -> String? {
        let messages = conversationStore.messages(for: sessionStore.selectedSessionID)
        return ConversationTimelineItemBuilder.items(from: messages).last?.id
    }
}

private enum KeyboardDismissal {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private final class ConversationTimelineItemCache {
    private var keys: [ConversationTimelineCacheKey] = []
    private var cachedItems: [ConversationTimelineItem] = []

    func items(from messages: [ConversationMessage]) -> [ConversationTimelineItem] {
        let nextKeys = messages.map { ConversationTimelineCacheKey(message: $0) }
        guard nextKeys != keys else {
            return cachedItems
        }
        let nextItems = ConversationTimelineItemBuilder.items(from: messages)
        keys = nextKeys
        cachedItems = nextItems
        return nextItems
    }

    func removeAll() {
        keys.removeAll()
        cachedItems.removeAll()
    }
}

private struct ConversationTimelineCacheKey: Equatable {
    let id: UUID
    let stableID: MessageID?
    let clientMessageID: ClientMessageID?
    let turnID: TurnID?
    let itemID: AgentItemID?
    let role: ConversationMessage.Role
    let kind: MessageKind
    let createdAt: Date
    let updatedAt: Date?
    let sendStatus: MessageSendStatus
    let revision: ModelRevision?
    let renderFingerprint: ConversationMessageRenderFingerprint
    let turnPayload: CodexAppServerTurnPayload?
    let activityPayload: ConversationActivityPayload?
    let isTimestampFallback: Bool

    init(message: ConversationMessage) {
        self.id = message.id
        self.stableID = message.stableID
        self.clientMessageID = message.clientMessageID
        self.turnID = message.turnID
        self.itemID = message.itemID
        self.role = message.role
        self.kind = message.kind
        self.createdAt = message.createdAt
        self.updatedAt = message.updatedAt
        self.sendStatus = message.sendStatus
        self.revision = message.revision
        self.renderFingerprint = message.renderFingerprint
        self.turnPayload = message.turnPayload
        self.activityPayload = message.activityPayload
        self.isTimestampFallback = message.isTimestampFallback
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
        let preview = ProcessedActivityPreviewModel(messages: group.messages, maxRows: collapsedPreviewLimit)

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if isExpanded || preview.items.isEmpty {
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
                }

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(group.messages) { message in
                            RuntimeSummaryCard(message: message, layout: layout)
                        }
                    }
                    .padding(.top, 8)
                    .transition(.opacity)
                } else if !preview.items.isEmpty {
                    Button(action: toggle) {
                        ProcessedActivityPreview(model: preview)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("展开已处理过程，\(group.title)")
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

    private var collapsedPreviewLimit: Int {
        layout.assistantBubbleMaxWidth < 560 ? 4 : 5
    }
}

private struct ProcessedActivityPreview: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let model: ProcessedActivityPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(model.items) { item in
                ProcessedActivityPreviewRow(item: item)
            }
            if model.hiddenOriginalCount > 0 {
                Text("另有 \(model.hiddenOriginalCount) 个过程项，展开查看")
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }
}

private struct ProcessedActivityPreviewRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let item: ProcessedActivityPreviewItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.symbolName)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(item.title)
                        .font(themeStore.uiFont(.caption, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.right")
                        .font(themeStore.uiFont(.caption2, weight: .semibold))
                        .foregroundStyle(tokens.secondaryText.opacity(0.9))
                }
                if let detail = item.detail {
                    Text(detail)
                        .font(themeStore.uiFont(.caption2))
                        .foregroundStyle(tokens.secondaryText.opacity(0.82))
                        .lineLimit(item.prefersExpandedDetail ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tint: Color {
        switch item.style {
        case .editFile, .approval:
            return tokens.accent
        case .error:
            return .red
        case .browseFile, .search, .runCommand, .toolCall, .thinking, .userInput, .other:
            return tokens.secondaryText
        }
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }
}

private struct ProcessedActivityPreviewModel: Equatable {
    let items: [ProcessedActivityPreviewItem]
    let hiddenOriginalCount: Int

    init(messages: [ConversationMessage], maxRows: Int) {
        let units = messages.map { ProcessedActivityPreviewUnit(message: $0) }
        guard !units.isEmpty else {
            items = []
            hiddenOriginalCount = 0
            return
        }

        // 折叠态不是完整日志：单一类型时给更多上下文，多类型时按语义聚合成小模块。
        let styles = Set(units.map(\.style))
        if styles == [.thinking] {
            items = [ProcessedActivityPreviewItem.aggregate(style: .thinking, units: units)]
            hiddenOriginalCount = 0
        } else if styles.count == 1 {
            let limit = min(maxRows + 1, 6)
            items = Array(units.prefix(limit).map { $0.detailedItem })
            hiddenOriginalCount = max(0, units.count - items.count)
        } else {
            let groupedUnits = Self.groupedByStyle(units)
            let orderedGroups = Self.prioritized(groups: groupedUnits)
            items = Array(orderedGroups.prefix(maxRows).map { style, units in
                ProcessedActivityPreviewItem.aggregate(style: style, units: units)
            })
            hiddenOriginalCount = orderedGroups.dropFirst(maxRows).reduce(0) { total, group in
                total + group.units.count
            }
        }
    }

    private static func groupedByStyle(_ units: [ProcessedActivityPreviewUnit]) -> [(style: ProcessedActivityPreviewStyle, units: [ProcessedActivityPreviewUnit])] {
        var orderedStyles: [ProcessedActivityPreviewStyle] = []
        var grouped: [ProcessedActivityPreviewStyle: [ProcessedActivityPreviewUnit]] = [:]
        for unit in units {
            if grouped[unit.style] == nil {
                orderedStyles.append(unit.style)
            }
            grouped[unit.style, default: []].append(unit)
        }
        return orderedStyles.compactMap { style in
            guard let units = grouped[style] else {
                return nil
            }
            return (style, units)
        }
    }

    private static func prioritized(
        groups: [(style: ProcessedActivityPreviewStyle, units: [ProcessedActivityPreviewUnit])]
    ) -> [(style: ProcessedActivityPreviewStyle, units: [ProcessedActivityPreviewUnit])] {
        groups.sorted { lhs, rhs in
            let leftPriority = lhs.style.mixedPreviewPriority
            let rightPriority = rhs.style.mixedPreviewPriority
            guard leftPriority == rightPriority else {
                return leftPriority < rightPriority
            }
            let leftOrdinal = lhs.units.first?.ordinal ?? 0
            let rightOrdinal = rhs.units.first?.ordinal ?? 0
            return leftOrdinal < rightOrdinal
        }
    }
}

private struct ProcessedActivityPreviewItem: Identifiable, Equatable {
    let id: String
    let style: ProcessedActivityPreviewStyle
    let title: String
    let detail: String?
    let symbolName: String
    let prefersExpandedDetail: Bool

    static func aggregate(style: ProcessedActivityPreviewStyle, units: [ProcessedActivityPreviewUnit]) -> ProcessedActivityPreviewItem {
        let title: String
        let detail: String?
        switch style {
        case .browseFile:
            let count = Self.fileCount(in: units)
            title = "已浏览 \(count) 个文件"
            detail = units.count == 1 ? units.first?.detail : nil
        case .search:
            title = "已搜索 \(units.count) 次"
            detail = units.count == 1 ? units.first?.title : nil
        case .runCommand:
            title = units.count == 1 ? (units.first?.completedTitle ?? "已运行 1 条命令") : "已运行 \(units.count) 条命令"
            detail = units.count == 1 ? units.first?.detail : nil
        case .editFile:
            title = "已编辑 \(Self.fileCount(in: units)) 个文件"
            detail = units.count == 1 ? units.first?.detail : nil
        case .toolCall:
            title = units.count == 1 ? (units.first?.completedTitle ?? "已调用 1 个工具") : "已调用 \(units.count) 个工具"
            detail = units.count == 1 ? units.first?.detail : nil
        case .thinking:
            title = units.count == 1 ? "推理摘要" : "推理摘要 \(units.count) 条"
            detail = units.compactMap(\.detail).first
        case .approval:
            title = units.count == 1 ? "处理审批" : "处理 \(units.count) 个审批"
            detail = units.count == 1 ? units.first?.detail : nil
        case .userInput:
            title = units.count == 1 ? "补充信息" : "补充信息 \(units.count) 次"
            detail = units.count == 1 ? units.first?.detail : nil
        case .error:
            title = units.count == 1 ? "运行异常" : "运行异常 \(units.count) 条"
            detail = units.first?.detail
        case .other:
            title = units.count == 1 ? (units.first?.title ?? "过程项") : "已处理 \(units.count) 个过程项"
            detail = units.count == 1 ? units.first?.detail : nil
        }

        return ProcessedActivityPreviewItem(
            id: "aggregate:\(style.rawValue)",
            style: style,
            title: title,
            detail: detail?.trimmedPreview(limit: 120),
            symbolName: style.symbolName,
            prefersExpandedDetail: false
        )
    }

    private static func fileCount(in units: [ProcessedActivityPreviewUnit]) -> Int {
        var seen: Set<String> = []
        var count = 0
        for path in units.flatMap(\.filePaths) {
            if seen.insert(path).inserted {
                count += 1
            }
        }
        return max(count, units.count)
    }
}

private struct ProcessedActivityPreviewUnit: Equatable {
    let ordinal: Int
    let messageID: UUID
    let style: ProcessedActivityPreviewStyle
    let title: String
    let completedTitle: String?
    let detail: String?
    let filePaths: [String]

    init(message: ConversationMessage) {
        ordinal = Int(message.createdAt.timeIntervalSinceReferenceDate * 1_000)
        messageID = message.id
        if let payload = message.activityPayload {
            style = ProcessedActivityPreviewStyle(payload: payload)
            title = Self.title(for: payload)
            completedTitle = Self.completedTitle(for: payload, style: style)
            detail = Self.detail(for: payload)
            filePaths = payload.filePaths
        } else {
            style = ProcessedActivityPreviewStyle(kind: message.kind)
            title = Self.fallbackTitle(for: message)
            completedTitle = nil
            detail = Self.firstContentLine(in: message.content)
            filePaths = []
        }
    }

    var detailedItem: ProcessedActivityPreviewItem {
        ProcessedActivityPreviewItem(
            id: "message:\(messageID.uuidString)",
            style: style,
            title: title,
            detail: detail?.trimmedPreview(limit: 180),
            symbolName: style.symbolName,
            prefersExpandedDetail: true
        )
    }

    private static func title(for payload: ConversationActivityPayload) -> String {
        if payload.category == .runCommand {
            if payload.displayTitle.hasPrefix("查看 ") ||
                payload.displayTitle.hasPrefix("列出 ") ||
                payload.displayTitle.hasPrefix("搜索 ") {
                return payload.displayTitle
            }
            if isRunning(payload.status) {
                return "正在运行 \(commandSubject(for: payload))"
            }
            return "运行 \(commandSubject(for: payload))"
        }
        return payload.displayTitle
    }

    private static func completedTitle(for payload: ConversationActivityPayload, style: ProcessedActivityPreviewStyle) -> String? {
        switch style {
        case .browseFile:
            return "已浏览 1 个文件"
        case .search:
            return "已搜索 1 次"
        case .runCommand:
            if let exitCode = payload.exitCode, exitCode != 0 {
                return "命令失败 \(commandSubject(for: payload))"
            }
            return "已运行 \(commandSubject(for: payload))"
        case .editFile:
            return "已编辑 \(max(payload.filePaths.count, 1)) 个文件"
        case .toolCall:
            return "已调用 \(payload.toolName ?? payload.displayTitle)"
        case .thinking, .approval, .userInput, .error, .other:
            return nil
        }
    }

    private static func detail(for payload: ConversationActivityPayload) -> String? {
        switch payload.category {
        case .thinking, .plan, .error:
            return payload.subtitle
        case .runCommand:
            return payload.outputPreview ?? payload.cwd ?? commandSubject(for: payload)
        case .editFile:
            if payload.filePaths.isEmpty {
                return payload.subtitle
            }
            return payload.filePaths.prefix(4).joined(separator: ", ")
        case .toolCall:
            return payload.status ?? payload.toolName
        }
    }

    private static func fallbackTitle(for message: ConversationMessage) -> String {
        switch message.kind {
        case .plan:
            return "计划"
        case .reasoningSummary:
            return "推理摘要"
        case .commandSummary:
            return "运行命令"
        case .fileChangeSummary:
            return "编辑文件"
        case .approval:
            return "处理审批"
        case .userInput:
            return "补充信息"
        case .error:
            return "运行异常"
        case .message:
            return firstContentLine(in: message.content) ?? "状态"
        }
    }

    private static func commandSubject(for payload: ConversationActivityPayload) -> String {
        if let command = payload.command?.trimmedNonEmpty {
            return stripShellWrapper(from: command)
        }
        return stripShellWrapper(from: payload.displayTitle)
            .removingPrefix("运行 ")
            .removingPrefix("正在运行 ")
    }

    private static func stripShellWrapper(from command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let shellPrefixes = [
            "/bin/zsh -lc ",
            "/usr/bin/zsh -lc ",
            "zsh -lc ",
            "/bin/bash -lc ",
            "/usr/bin/bash -lc ",
            "bash -lc "
        ]
        guard let prefix = shellPrefixes.first(where: { trimmed.hasPrefix($0) }) else {
            return trimmed
        }
        let script = String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return unquoteShellArgument(script)
    }

    private static func unquoteShellArgument(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "'" && last == "'") || (first == "\"" && last == "\"")
        else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private static func firstContentLine(in text: String) -> String? {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmedNonEmpty
    }

    private static func isRunning(_ status: String?) -> Bool {
        guard let status = status?.lowercased() else {
            return false
        }
        return status == "running" || status == "in_progress" || status == "started"
    }
}

private enum ProcessedActivityPreviewStyle: String, Equatable, Hashable {
    case browseFile
    case search
    case runCommand
    case editFile
    case toolCall
    case thinking
    case approval
    case userInput
    case error
    case other

    init(payload: ConversationActivityPayload) {
        switch payload.category {
        case .thinking:
            self = .thinking
        case .plan:
            self = .other
        case .runCommand:
            if payload.displayTitle.hasPrefix("查看 ") || payload.displayTitle.hasPrefix("列出 ") {
                self = .browseFile
            } else if payload.displayTitle.hasPrefix("搜索 ") || payload.displayTitle.hasPrefix("网络搜索") {
                self = .search
            } else {
                self = .runCommand
            }
        case .editFile:
            self = .editFile
        case .toolCall:
            self = .toolCall
        case .error:
            self = .error
        }
    }

    init(kind: MessageKind) {
        switch kind {
        case .reasoningSummary:
            self = .thinking
        case .commandSummary:
            self = .runCommand
        case .fileChangeSummary:
            self = .editFile
        case .approval:
            self = .approval
        case .userInput:
            self = .userInput
        case .error:
            self = .error
        case .plan, .message:
            self = .other
        }
    }

    var mixedPreviewPriority: Int {
        switch self {
        case .error:
            return 0
        case .browseFile, .search, .editFile, .runCommand, .toolCall:
            return 1
        case .approval, .userInput:
            return 2
        case .other:
            return 3
        case .thinking:
            return 4
        }
    }

    var symbolName: String {
        switch self {
        case .browseFile, .runCommand:
            return "terminal"
        case .search:
            return "magnifyingglass"
        case .editFile:
            return "pencil"
        case .toolCall:
            return "wrench.and.screwdriver"
        case .thinking:
            return "brain.head.profile"
        case .approval:
            return "checkmark.seal"
        case .userInput:
            return "questionmark.bubble"
        case .error:
            return "exclamationmark.triangle"
        case .other:
            return "info.circle"
        }
    }
}

private enum ProcessedActivitySymbol {
    static func symbolName(for category: ConversationActivityCategory) -> String {
        switch category {
        case .thinking:
            return "brain.head.profile"
        case .plan:
            return "list.clipboard"
        case .runCommand:
            return "terminal"
        case .editFile:
            return "doc.text"
        case .toolCall:
            return "wrench.and.screwdriver"
        case .error:
            return "exclamationmark.triangle"
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
    let showsActiveDeliveryStatus: Bool

    // 只有内容 fingerprint / 状态变化时才重绘；长消息内容本身不参与这里的逐行比较。
    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.role == rhs.message.role
            && lhs.message.kind == rhs.message.kind
            && lhs.message.sendStatus == rhs.message.sendStatus
            && lhs.message.revision == rhs.message.revision
            && lhs.message.userDelivery == rhs.message.userDelivery
            && lhs.message.createdAt == rhs.message.createdAt
            && lhs.message.updatedAt == rhs.message.updatedAt
            && lhs.message.renderFingerprint == rhs.message.renderFingerprint
            && lhs.message.turnPayload == rhs.message.turnPayload
            && lhs.message.activityPayload == rhs.message.activityPayload
            && lhs.themeVersion == rhs.themeVersion
            && lhs.layout == rhs.layout
            && lhs.showsActiveDeliveryStatus == rhs.showsActiveDeliveryStatus
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
            deliveryCaption(sendingDeliveryCaption)
        case .sent:
            if message.userDelivery == .injected {
                deliveryCaption("已引导对话")
            } else if showsActiveDeliveryStatus {
                deliveryCaption("已送达，等待回复")
            }
        case .confirmed:
            if message.userDelivery == .injected {
                deliveryCaption("已引导对话")
            }
        case .local:
            deliveryCaption(message.userDelivery == .queued ? "已排队，等待当前回复完成" : "待发送")
        }
    }

    private var sendingDeliveryCaption: String {
        switch message.userDelivery {
        case .queued:
            return "排队发送中…"
        case .guided, .injected:
            return "引导发送中…"
        case nil:
            return "发送中…"
        }
    }

    private func deliveryCaption(_ text: String) -> some View {
        Text(text)
            .font(themeStore.uiFont(.caption2))
            .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
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
        bubbleSurface
            .frame(maxWidth: maxBubbleWidth, alignment: bubbleAlignment)
            .opacity(message.sendStatus == .sending ? 0.72 : 1)
            .quickLookPreview($previewURL)
    }

    private var bubbleSurface: some View {
        bubbleChrome
            // 长按菜单必须锚定在实际气泡上，不能挂到外层全宽行，否则 iPad 上菜单预览会撑满整行。
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .messageContextMenu(
                for: message,
                retry: {
                    Task { await sessionStore.retryFailedUserMessage(message) }
                },
                stop: {
                    sessionStore.sendCtrlC()
                },
                preview: {
                    bubbleChrome
                        .frame(maxWidth: maxBubbleWidth, alignment: bubbleAlignment)
                }
            )
    }

    private var bubbleChrome: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return contentWithTimestamp
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(background, in: shape)
            .overlay {
                shape.strokeBorder(bubbleBorder, lineWidth: 1)
            }
            .shadow(color: bubbleShadowColor, radius: message.role == .user ? 2 : 6, y: message.role == .user ? 1 : 2)
    }

    private var contentWithTimestamp: some View {
        ZStack(alignment: .bottomTrailing) {
            renderContent
                .padding(.bottom, 16)
            MessageTimestampCaption(text: message.timestampCaptionText, isFallback: message.isTimestampFallback, foreground: timestampForeground)
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
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func userImageContent(style: MarkdownStyle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let text = userImageText
            if !text.isEmpty {
                Text(text)
                    .font(style.bodyFont)
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

    private var bubbleBorder: Color {
        let tokens = themeStore.tokens(for: colorScheme)
        if message.role == .user, tokens.preset == .codex {
            return Color.white.opacity(tokens.resolvedScheme == .light ? 0.12 : 0.08)
        }
        return tokens.border.opacity(message.role == .assistant ? 0.58 : 0.42)
    }

    private var bubbleShadowColor: Color {
        let tokens = themeStore.tokens(for: colorScheme)
        let opacity: Double
        if message.role == .user {
            opacity = tokens.resolvedScheme == .light ? 0.05 : 0.12
        } else {
            opacity = tokens.resolvedScheme == .light ? 0.045 : 0.16
        }
        return Color.black.opacity(opacity)
    }

    private var foreground: Color {
        let tokens = themeStore.tokens(for: colorScheme)
        if message.role == .user, tokens.preset == .codex {
            return userBubbleForeground
        }
        return tokens.primaryText
    }

    private var timestampForeground: Color? {
        let tokens = themeStore.tokens(for: colorScheme)
        guard message.role == .user, tokens.preset == .codex else {
            return nil
        }
        return userBubbleForeground.opacity(0.72)
    }

    private var userBubbleForeground: Color {
        themeStore.tokens(for: colorScheme).userBubbleForeground
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
        noticeSurface
            .contentShape(Capsule())
            .messageContextMenu(for: message) {
                noticeSurface
                    .frame(maxWidth: layout.systemMaxWidth)
            }
            .frame(maxWidth: layout.systemMaxWidth)
    }

    private var noticeSurface: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return ZStack(alignment: .bottomTrailing) {
            Text(message.content)
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            MessageTimestampCaption(text: message.timestampCaptionText, isFallback: message.isTimestampFallback)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tokens.systemBubble, in: Capsule())
    }
}

private struct RuntimeSummaryCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationMessage
    let layout: ConversationLayout

    var body: some View {
        cardSurface
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .messageContextMenu(for: message) {
                cardSurface
                    .frame(maxWidth: cardMaxWidth, alignment: .leading)
            }
            .frame(maxWidth: cardMaxWidth, alignment: .leading)
    }

    private var cardSurface: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbolName)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                contentView
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    MessageTimestampCaption(text: message.timestampCaptionText, isFallback: message.isTimestampFallback)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if let payload = message.activityPayload {
            activityContent(payload)
        } else if message.kind == .plan {
            planMarkdownContent
        } else {
            Text(message.content)
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(3)
        }
    }

    private func activityContent(_ payload: ConversationActivityPayload) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if payload.category == .plan {
                planMarkdownContent
            } else if payload.category == .thinking, let subtitle = payload.subtitle {
                Text(subtitle)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(3)
            } else {
                if let command = payload.command {
                    activityDetailRow("命令", value: command, monospaced: true)
                }
                if let cwd = payload.cwd {
                    activityDetailRow("目录", value: cwd, monospaced: true)
                }
                if !payload.filePaths.isEmpty {
                    activityDetailRow("文件", value: payload.filePaths.prefix(5).joined(separator: ", "), monospaced: true)
                }
                if let toolName = payload.toolName, payload.category == .toolCall {
                    activityDetailRow("工具", value: toolName, monospaced: true)
                }
                let statusText = [payload.status.map { "状态 \($0)" }, payload.exitCode.map { "退出码 \($0)" }]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(themeStore.uiFont(.caption2, weight: .medium))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                if let output = payload.outputPreview {
                    Text(output)
                        .font(themeStore.uiFont(.caption2).monospaced())
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityDetailRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(tokens.secondaryText.opacity(0.82))
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(monospaced ? themeStore.uiFont(.caption2).monospaced() : themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var planMarkdownContent: some View {
        let style = MarkdownStyle.make(
            role: .assistant,
            colorScheme: colorScheme,
            fontScale: themeStore.fontScale * 0.94,
            tokens: tokens
        )
        let plan = MessageRenderPlanCache.shared.plan(for: message)
        let blocks = displayBlocks(for: plan)

        return VStack(alignment: .leading, spacing: style.blockSpacing) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block, style: style)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardMaxWidth: CGFloat {
        message.kind == .plan ? layout.assistantBubbleMaxWidth : layout.runtimeCardMaxWidth
    }

    private func displayBlocks(for plan: MessageRenderPlan) -> [MarkdownBlock] {
        guard plan.blocks.count == 1,
              case let .proposedPlan(blocks, _) = plan.blocks[0].kind
        else {
            return plan.blocks
        }
        return blocks
    }

    private var title: String {
        if let payload = message.activityPayload {
            return payload.displayTitle
        }
        switch message.kind {
        case .plan:
            return "计划"
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
        case .userInput:
            if message.content.hasPrefix("已跳过补充信息") || message.content.hasPrefix("已跳过引导输入") {
                return "补充信息已跳过"
            }
            if message.content.hasPrefix("补充信息已提交") || message.content.hasPrefix("引导输入已提交") {
                return "补充信息已提交"
            }
            return "等待补充信息"
        case .error:
            return "运行异常"
        case .message:
            return "状态"
        }
    }

    private var symbolName: String {
        if let category = message.activityPayload?.category {
            return ProcessedActivitySymbol.symbolName(for: category)
        }
        switch message.kind {
        case .plan:
            return "list.clipboard"
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
        case .userInput:
            return "questionmark.bubble"
        case .error:
            return "exclamationmark.triangle"
        case .message:
            return "info.circle"
        }
    }

    private var tint: Color {
        if let category = message.activityPayload?.category {
            switch category {
            case .plan, .editFile:
                return tokens.accent
            case .error:
                return .red
            case .thinking, .runCommand, .toolCall:
                return tokens.secondaryText
            }
        }
        switch message.kind {
        case .plan:
            return tokens.accent
        case .approval:
            if isApprovedApproval {
                return tokens.success
            }
            if isDeclinedApproval {
                return .red
            }
            return tokens.warning
        case .userInput:
            return tokens.accent
        case .error:
            return .red
        case .fileChangeSummary:
            return tokens.accent
        default:
            return tokens.secondaryText
        }
    }

    private var background: Color {
        if let category = message.activityPayload?.category {
            switch category {
            case .plan:
                return tokens.accent.opacity(0.08)
            case .editFile:
                return tokens.accent.opacity(0.10)
            case .error:
                return Color.red.opacity(0.10)
            case .thinking, .runCommand, .toolCall:
                return tokens.systemBubble
            }
        }
        switch message.kind {
        case .plan:
            return tokens.accent.opacity(0.08)
        case .approval:
            if isApprovedApproval {
                return tokens.success.opacity(0.10)
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

private extension View {
    func messageContextMenu<Preview: View>(
        for message: ConversationMessage,
        retry: (() -> Void)? = nil,
        stop: (() -> Void)? = nil,
        @ViewBuilder preview: @escaping () -> Preview
    ) -> some View {
        _ = preview
        // iPadOS 对 contextMenu 自定义预览会重新构建复杂 Markdown/图片气泡，长按时容易触发 SwiftUI 内部崩溃；
        // 这里保留复制/重试/停止动作，禁用预览来换取稳定性。
        return contextMenu {
            Button {
                UIPasteboard.general.string = message.content
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }

            if message.role == .user && message.sendStatus == .failed, let retry {
                Button(action: retry) {
                    Label("重试", systemImage: "arrow.clockwise")
                }
            }

            if message.role == .assistant && message.sendStatus == .sending, let stop {
                Button(role: .destructive, action: stop) {
                    Label("停止", systemImage: "stop.circle")
                }
            }
        }
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else {
            return self
        }
        return String(dropFirst(prefix.count))
    }

    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func trimmedPreview(limit: Int) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else {
            return trimmed
        }
        return String(trimmed.prefix(limit)) + "..."
    }
}

private struct MessageTimestampCaption: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    var isFallback = false
    var foreground: Color?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        Text(text)
            .font(themeStore.uiFont(.caption2, weight: .medium))
            .foregroundStyle(isFallback ? tokens.warning : (foreground ?? tokens.tertiaryText))
            .lineLimit(1)
            .minimumScaleFactor(0.88)
            .accessibilityLabel(isFallback ? "消息时间 兜底估算 \(text)" : "消息时间 \(text)")
    }
}

extension ConversationMessage {
    var timestampCaptionText: String {
        let text: String
        switch role {
        case .user:
            text = "发出 \(Self.compactTime(createdAt))"
        case .assistant:
            guard sendStatus != .sending else {
                let started = Self.compactTime(createdAt)
                guard let updatedAt else {
                    return "开始 \(started)"
                }
                let latest = Self.compactTime(updatedAt)
                return started == latest ? "开始 \(started)" : "开始 \(started) · 最近 \(latest)"
            }
            let completedAt = updatedAt ?? createdAt
            let started = Self.compactTime(createdAt)
            let completed = Self.compactTime(completedAt)
            // 同一分钟内开始和完成显示相同时间时，只保留完成时间，减少气泡右下角噪音。
            if started == completed {
                text = "完成 \(completed)"
            } else {
                text = "开始 \(started) · 完成 \(completed)"
            }
        case .system:
            if let updatedAt, Self.compactTime(updatedAt) != Self.compactTime(createdAt) {
                text = "\(Self.compactTime(createdAt)) · \(Self.compactTime(updatedAt))"
            } else {
                text = Self.compactTime(createdAt)
            }
        }
        return text
    }

    private static func compactTime(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }
}
