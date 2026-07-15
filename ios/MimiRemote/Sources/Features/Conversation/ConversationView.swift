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
    case activity(ConversationMessage)
    case exploration(ConversationExplorationGroup)

    var id: String {
        switch self {
        case .message(let message):
            return "message:\(message.id.uuidString)"
        case .activity(let message):
            return "activity:\(message.id.uuidString)"
        case .exploration(let group):
            return group.id
        }
    }
}

struct ConversationExplorationGroup: Identifiable, Equatable {
    let id: String
    let messages: [ConversationMessage]
    let isCompleted: Bool

    var title: String {
        isCompleted ? "已探索 \(messages.count) 项" : "正在探索 \(messages.count) 项"
    }

    var latestDetail: String? {
        messages.last?.activityPayload?.displayTitle.trimmedNonEmpty
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
                // app-server 事件可能先到最终 assistant、后到 diff；仍按 turnID 把过程归位到
                // 最终回答之前，但不再压成一个会整体展开的手风琴。
                items.append(contentsOf: activityItems(from: processMessages, turnCompleted: true))
                insertedProcessTurnIDs.insert(turnID)
            }
            guard isActivityMessage(message) else {
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

            if isExplorationMessage(message) {
                var explorationMessages: [ConversationMessage] = []
                while index < messages.endIndex,
                      isExplorationMessage(messages[index]),
                      belongsToSameExplorationGroup(message, messages[index]) {
                    explorationMessages.append(messages[index])
                    index = messages.index(after: index)
                }
                let turnCompleted = fallbackCompletedAssistant(
                    for: explorationMessages,
                    nextIndex: index,
                    messages: messages
                ) != nil
                items.append(.exploration(explorationGroup(from: explorationMessages, turnCompleted: turnCompleted)))
            } else {
                items.append(.activity(message))
                index = messages.index(after: index)
            }
        }

        return items
    }

    private static func isActivityMessage(_ message: ConversationMessage) -> Bool {
        guard message.role == .system else {
            return false
        }
        switch message.kind {
        case .reasoningSummary, .commandSummary, .fileChangeSummary:
            return true
        case .approval, .userInput:
            return isResolvedInteractionMessage(message)
        case .plan, .error, .message:
            return false
        }
    }

    private static func isResolvedInteractionMessage(_ message: ConversationMessage) -> Bool {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch message.kind {
        case .approval:
            return content.hasPrefix("审批已批准") ||
                content.hasPrefix("已批准") ||
                content.hasPrefix("审批已拒绝") ||
                content.hasPrefix("已拒绝")
        case .userInput:
            return content.hasPrefix("补充信息已提交") ||
                content.hasPrefix("引导输入已提交") ||
                content.hasPrefix("已跳过补充信息") ||
                content.hasPrefix("已跳过引导输入")
        case .message, .plan, .reasoningSummary, .commandSummary, .fileChangeSummary, .error:
            return false
        }
    }

    private static func isExplorationMessage(_ message: ConversationMessage) -> Bool {
        guard isActivityMessage(message),
              let payload = message.activityPayload,
              payload.category == .runCommand
        else {
            return false
        }
        return payload.displayTitle.hasPrefix("查看 ") ||
            payload.displayTitle.hasPrefix("列出 ") ||
            payload.displayTitle.hasPrefix("搜索 ")
    }

    private static func belongsToSameExplorationGroup(
        _ first: ConversationMessage,
        _ candidate: ConversationMessage
    ) -> Bool {
        first.turnID == candidate.turnID
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
                  isActivityMessage(message)
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

    private static func activityItems(
        from messages: [ConversationMessage],
        turnCompleted: Bool
    ) -> [ConversationTimelineItem] {
        var result: [ConversationTimelineItem] = []
        var explorations: [ConversationMessage] = []

        func flushExplorations() {
            guard !explorations.isEmpty else {
                return
            }
            result.append(.exploration(explorationGroup(from: explorations, turnCompleted: turnCompleted)))
            explorations.removeAll(keepingCapacity: true)
        }

        for message in messages {
            if isExplorationMessage(message) {
                explorations.append(message)
            } else {
                flushExplorations()
                result.append(.activity(message))
            }
        }
        flushExplorations()
        return result
    }

    private static func explorationGroup(
        from messages: [ConversationMessage],
        turnCompleted: Bool
    ) -> ConversationExplorationGroup {
        let firstID = messages.first?.id.uuidString ?? UUID().uuidString
        let allItemsTerminal = messages.allSatisfy { message in
            guard let status = message.activityPayload?.status?.lowercased() else {
                return false
            }
            return status == "completed" || status == "failed" || status == "cancelled"
        }
        return ConversationExplorationGroup(
            // 只使用第一条探索事件作为身份；后续追加和回合完成只更新同一行，不触发 List 换行重锚。
            id: "exploration:\(firstID)",
            messages: messages,
            isCompleted: turnCompleted || allItemsTerminal
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
        // safeAreaInset 已经负责系统手势区；这里只保留卡片与安全区之间的轻量呼吸感，
        // 避免两层底距叠加后让输入卡看起来悬得过高。
        composerBottomPadding = isCompactWidth ? 8 : 10

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
    @State private var expandedActivityIDs: Set<String> = []
    @State private var timelineItemCache = ConversationTimelineItemCache()
    @State private var pendingTailScrollTask: Task<Void, Never>?
    @State private var tailScrollAttemptGeneration = 0
    @State private var userScrollAwayGeneration = 0

    private let messageTailFollowThreshold: CGFloat = 120
    private static let timelineTailSentinelID = "__conversation_timeline_safe_tail__"

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
                // 用 List 替代 ScrollView + LazyVStack：行高是真实测量值、
                // 有 cell 复用，scrollTo 对尚未实例化的行也可靠。这样既消除首屏/切换会话
                // “空白要手滑一下”的竞态，右侧滚动条也不再因 LazyVStack 高度估算而长度/位置乱跳。
                List {
                    Section {
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
                                timelineRow(
                                    item,
                                    activeUserDeliveryMessageID: activeUserDeliveryMessageID,
                                    proxy: proxy
                                )
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

                    Section {
                        // 尾部哨兵独占固定 Section，始终是 row 0。消息增删只影响前一个
                        // Section，scrollTo 不会把新快照行号用于旧 UICollectionView 快照。
                        Color.clear
                            .frame(height: 1)
                            .id(Self.timelineTailSentinelID)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                // 每个会话使用独立的 List 身份，避免复用上一个会话的 contentOffset；
                // 挂载后再定位到固定尾部哨兵。
                .id(sessionStore.selectedSessionID)
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
                expandedActivityIDs.removeAll()
                timelineItemCache.removeAll()
                cancelPendingTailScrollAttempts()
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
                // 新探索组或独立进度行出现时，只有用户原本贴底才继续跟随。
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
    private func timelineRow(
        _ item: ConversationTimelineItem,
        activeUserDeliveryMessageID: UUID?,
        proxy: ScrollViewProxy
    ) -> some View {
        switch item {
        case .message(let message):
            MessageRow(
                message: message,
                themeVersion: themeStore.themeVersion,
                layout: layout,
                showsActiveDeliveryStatus: message.id == activeUserDeliveryMessageID
            )
                .equatable()
        case .activity(let message):
            ConversationActivityRow(
                message: message,
                layout: layout,
                isExpanded: expandedActivityIDs.contains(item.id),
                toggle: {
                    toggleActivityDetails(itemID: item.id, proxy: proxy)
                }
            )
                .equatable()
        case .exploration(let group):
            ConversationExplorationRow(group: group, layout: layout)
                .equatable()
        }
    }

    private func toggleActivityDetails(itemID: String, proxy: ScrollViewProxy) {
        let isExpanding = !expandedActivityIDs.contains(itemID)
        if isExpanding {
            expandedActivityIDs.insert(itemID)
        } else {
            expandedActivityIDs.remove(itemID)
        }
        guard isExpanding, isTimelineNearBottom else {
            return
        }
        Task { @MainActor in
            await Task.yield()
            guard expandedActivityIDs.contains(itemID) else {
                return
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(itemID, anchor: .bottom)
            }
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
        guard !timelineItems.isEmpty else {
            return
        }
        guard !isPreservingHistoryScroll else {
            return
        }
        shouldFollowMessageTail = true
        hasUnseenTailMessage = false
        isTimelineNearBottom = true
        forceNextMessageTailScroll = false
        scrollToTimelineTail(proxy: proxy, animated: animated)
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

    private func scrollToTimelineTail(proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(Self.timelineTailSentinelID, anchor: .bottom)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(Self.timelineTailSentinelID, anchor: .bottom)
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

private struct ConversationExplorationRow: View, Equatable {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let group: ConversationExplorationGroup
    let layout: ConversationLayout

    static func == (lhs: ConversationExplorationRow, rhs: ConversationExplorationRow) -> Bool {
        lhs.group == rhs.group && lhs.layout == rhs.layout
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    if group.isCompleted {
                        Image(systemName: "circle.fill")
                            .font(themeStore.uiFont(size: 5, weight: .semibold))
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .frame(width: 14, height: 16)
                .foregroundStyle(tokens.secondaryText)

                Text(explorationText)
                    .font(themeStore.uiFont(.caption, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: layout.assistantBubbleMaxWidth, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(explorationText)

            Spacer(minLength: layout.messageSideSpacer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var explorationText: String {
        guard let detail = group.latestDetail else {
            return group.title
        }
        return "\(group.title) · \(detail)"
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }
}

private struct ConversationActivityRow: View, Equatable {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationMessage
    let layout: ConversationLayout
    let isExpanded: Bool
    let toggle: () -> Void

    static func == (lhs: ConversationActivityRow, rhs: ConversationActivityRow) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.renderFingerprint == rhs.message.renderFingerprint
            && lhs.message.activityPayload == rhs.message.activityPayload
            && lhs.layout == rhs.layout
            && lhs.isExpanded == rhs.isExpanded
    }

    var body: some View {
        HStack(spacing: 0) {
            rowSurface
                .messageContextMenu(for: message) {
                    rowSurface.frame(maxWidth: layout.assistantBubbleMaxWidth, alignment: .leading)
                }
                .frame(maxWidth: layout.assistantBubbleMaxWidth, alignment: .leading)

            Spacer(minLength: layout.messageSideSpacer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var rowSurface: some View {
        if hasExpandableDetails {
            Button(action: toggle) {
                rowContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel(activityTitle)
            .accessibilityValue(isExpanded ? "已展开" : "已收起")
            .accessibilityHint(isExpanded ? "收起当前过程详情" : "展开当前过程详情")
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(alignment: isReasoning ? .top : .firstTextBaseline, spacing: 8) {
            activityMarker

            if isReasoning {
                Text(reasoningText)
                    .font(themeStore.uiFont(.caption))
                    .italic()
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(isExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(activityTitle)
                        .font(themeStore.uiFont(.caption, weight: .medium))
                        .foregroundStyle(activityTint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = activityDetail {
                        Text(detail)
                            .font(themeStore.uiFont(.caption2))
                            .foregroundStyle(tokens.secondaryText.opacity(0.84))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if isExpanded {
                        expandedDetails
                            .padding(.top, 3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if hasExpandableDetails {
                Image(systemName: "chevron.right")
                    .font(themeStore.uiFont(.caption2, weight: .semibold))
                    .foregroundStyle(tokens.secondaryText.opacity(0.75))
                    .frame(width: 12, height: 16)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var expandedDetails: some View {
        if let payload = message.activityPayload {
            VStack(alignment: .leading, spacing: 4) {
                if let command = payload.command?.trimmedNonEmpty {
                    activityDetailLine("命令", value: command, monospaced: true)
                }
                if let cwd = payload.cwd?.trimmedNonEmpty {
                    activityDetailLine("目录", value: cwd, monospaced: true)
                }
                if !payload.filePaths.isEmpty {
                    activityDetailLine("文件", value: payload.filePaths.joined(separator: "\n"), monospaced: true)
                }
                let status = [
                    payload.displayStatusText,
                    payload.exitCode.map { "退出码 \($0)" }
                ]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                if !status.isEmpty {
                    activityDetailLine("状态", value: status)
                }
                if let output = payload.outputPreview?.trimmedNonEmpty {
                    Text(output)
                        .font(themeStore.uiFont(.caption2).monospaced())
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func activityDetailLine(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(tokens.secondaryText.opacity(0.76))
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(monospaced ? themeStore.uiFont(.caption2).monospaced() : themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var activityMarker: some View {
        if isRunning {
            ProgressView()
                .controlSize(.mini)
                .tint(activityTint)
                .frame(width: 14, height: 16)
        } else {
            Image(systemName: markerSymbol)
                .font(themeStore.uiFont(size: markerSymbol == "circle.fill" ? 5 : 11, weight: .semibold))
                .foregroundStyle(activityTint)
                .frame(width: 14, height: 16)
        }
    }

    private var isReasoning: Bool {
        message.kind == .reasoningSummary
    }

    private var reasoningText: String {
        ConversationActivityPayload.plainProgressText(
            message.activityPayload?.subtitle?.trimmedNonEmpty ?? message.content
        )
    }

    private var activityTitle: String {
        if let payload = message.activityPayload {
            return payload.displayTitle
        }
        switch message.kind {
        case .commandSummary:
            return message.content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "运行命令"
        case .fileChangeSummary:
            return message.content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "文件变更"
        case .approval:
            if isApprovedInteraction {
                return "审批已批准"
            }
            if isDeclinedInteraction {
                return "审批已拒绝"
            }
            return "审批状态"
        case .userInput:
            return isSkippedInteraction ? "已跳过补充信息" : "补充信息已提交"
        default:
            return message.content
        }
    }

    private var activityDetail: String? {
        guard let payload = message.activityPayload else {
            return interactionDetail
        }
        switch payload.category {
        case .editFile:
            return payload.filePaths.isEmpty ? payload.displayStatusText : payload.filePaths.prefix(4).joined(separator: ", ")
        case .runCommand:
            if let exitCode = payload.exitCode, exitCode != 0 {
                return "退出码 \(exitCode)"
            }
            return payload.cwd
        case .toolCall:
            return payload.displayStatusText == "已完成" ? nil : payload.displayStatusText
        case .thinking, .plan, .error:
            return payload.subtitle.map(ConversationActivityPayload.plainProgressText)
        }
    }

    private var interactionDetail: String? {
        guard message.kind == .approval || message.kind == .userInput else {
            return nil
        }
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = content.firstIndex(where: { $0 == "：" || $0 == ":" }) {
            return String(content[content.index(after: separator)...]).trimmedNonEmpty
        }
        return nil
    }

    private var hasExpandableDetails: Bool {
        if isReasoning {
            return reasoningText.count > 160 || reasoningText.filter { $0 == "\n" }.count >= 3
        }
        guard let payload = message.activityPayload else {
            return false
        }
        return payload.command?.trimmedNonEmpty != nil ||
            payload.cwd?.trimmedNonEmpty != nil ||
            !payload.filePaths.isEmpty ||
            payload.outputPreview?.trimmedNonEmpty != nil
    }

    private var isRunning: Bool {
        message.activityPayload?.isInProgress == true
    }

    private var isFailure: Bool {
        message.activityPayload?.isFailure == true
    }

    private var markerSymbol: String {
        if isFailure {
            return "exclamationmark.circle.fill"
        }
        if isApprovedInteraction || (message.kind == .userInput && !isSkippedInteraction) {
            return "checkmark.circle.fill"
        }
        if isDeclinedInteraction || isSkippedInteraction {
            return "xmark.circle"
        }
        if message.activityPayload?.category == .editFile {
            return "pencil"
        }
        return "circle.fill"
    }

    private var activityTint: Color {
        if isFailure {
            return .red
        }
        if isApprovedInteraction || (message.kind == .userInput && !isSkippedInteraction) {
            return tokens.success
        }
        if message.activityPayload?.category == .editFile {
            return tokens.accent
        }
        return tokens.secondaryText
    }

    private var isApprovedInteraction: Bool {
        message.kind == .approval &&
            (message.content.hasPrefix("审批已批准") || message.content.hasPrefix("已批准"))
    }

    private var isDeclinedInteraction: Bool {
        message.kind == .approval &&
            (message.content.hasPrefix("审批已拒绝") || message.content.hasPrefix("已拒绝"))
    }

    private var isSkippedInteraction: Bool {
        message.kind == .userInput &&
            (message.content.hasPrefix("已跳过补充信息") || message.content.hasPrefix("已跳过引导输入"))
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
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
        Group {
            if shouldRenderUserImages {
                userImageBubbleSurface
            } else {
                bubbleSurface
            }
        }
            .frame(maxWidth: maxBubbleWidth, alignment: bubbleAlignment)
            .opacity(message.sendStatus == .sending ? 0.72 : 1)
            .quickLookPreview($previewURL)
    }

    private var userImageBubbleSurface: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let style = MarkdownStyle.make(
            role: message.role,
            colorScheme: colorScheme,
            fontScale: themeStore.fontScale,
            tokens: tokens
        )
        return userImageContent(style: style)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .messageContextMenu(
                for: message,
                retry: {
                    Task { await sessionStore.retryFailedUserMessage(message) }
                },
                stop: {
                    sessionStore.sendCtrlC()
                },
                preview: {
                    userImageContent(style: style)
                        .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
                }
            )
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
        let tokens = themeStore.tokens(for: colorScheme)
        return VStack(alignment: .trailing, spacing: 8) {
            let text = userImageText
            if !text.isEmpty {
                Text(text)
                    .font(style.bodyFont)
                    .foregroundStyle(userBubbleForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(tokens.userBubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            userImageGallery(style: style)

            let accessoryText = payloadAccessoryText
            if !accessoryText.isEmpty {
                Text(accessoryText)
                    .font(style.captionFont)
                    .foregroundStyle(style.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            MessageTimestampCaption(
                text: message.timestampCaptionText,
                isFallback: message.isTimestampFallback,
                foreground: tokens.secondaryText
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func userImageGallery(style: MarkdownStyle) -> some View {
        if userImageSources.count > 1 {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                alignment: .trailing,
                spacing: 8
            ) {
                ForEach(userImageSources) { source in
                    ConversationImagePreview(
                        source: source,
                        title: nil,
                        style: style,
                        maxHeight: 208,
                        showsCaption: false,
                        fillsAvailableWidth: true
                    )
                    .frame(height: 220, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            ForEach(userImageSources) { source in
                ConversationImagePreview(
                    source: source,
                    title: nil,
                    style: style,
                    maxHeight: 320,
                    showsCaption: false,
                    fillsAvailableWidth: true
                )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
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

    private var userImageSources: [ConversationImageSource] {
        let payloadSources = payloadImageItems.compactMap(ConversationImageSource.input)
        if !payloadSources.isEmpty {
            return payloadSources
        }
        return contentImageReferences.map { .localPath($0.path) }
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
