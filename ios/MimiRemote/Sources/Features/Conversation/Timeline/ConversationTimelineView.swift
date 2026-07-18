import SwiftUI
import UIKit

struct ConversationTimelineView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var conversationStore: ConversationStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let layout: ConversationLayout
    @State private var shouldFollowMessageTail = true
    @State private var forceNextMessageTailScroll = true
    // 在会话切换、本地提交或用户主动“回到底部”后，旧 List 的滚动几何可能还会
    // 回报上一个会话的 offset。锁住跟随直到用户明确上翻，避免这份过期几何把
    // 新会话的首帧尾部定位提前关掉。
    @State private var isTailFollowLocked = false
    @State private var isTimelineNearBottom = true
    @State private var hasUnseenTailMessage = false
    @State private var isPreservingHistoryScroll = false
    @State private var expandedActivityIDs: Set<String> = []
    @State private var expandedActivityGroupIDs: Set<String> = []
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
                    } else if !isTailFollowLocked {
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
                let shouldPreserveTailFollowLock = isTailFollowLocked
                    && Self.isOptimisticSessionID(oldID)
                    && newID != nil
                shouldFollowMessageTail = true
                forceNextMessageTailScroll = true
                // 会话切换本来就要进入最新上下文。首帧 List 尚未替换前，旧会话的
                // geometry 可能先报“未贴底”；把锁延续到用户主动上翻，后续流式消息
                // 才不会被错误地当成历史阅读状态而停止重锚。
                isTailFollowLocked = newID != nil || shouldPreserveTailFollowLock
                hasUnseenTailMessage = false
                isTimelineNearBottom = true
                isPreservingHistoryScroll = false
                expandedActivityIDs.removeAll()
                expandedActivityGroupIDs.removeAll()
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
                // 首条活动会通过 timelineItemIDs 插入并触发尾部跟随；同一批次后续命令
                // 只更新摘要，不再为每个底层消息重复发起滚动。
                if !Self.shouldScheduleTailFollowForNewTailMessage(messages.last) {
                    return
                }
                if Self.shouldForceTailFollow(forNewTailMessage: messages.last) {
                    // 本地发送代表用户明确进入最新上下文；即使滚动几何刚好误判为“不在底部”，
                    // 也要立即贴到尾部，避免发完消息后还停在历史位置。
                    isTailFollowLocked = true
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
                // 只有助手正文流式增长才需要持续贴底。命令 stdout/stderr 已保存在详情中，
                // 折叠状态下不应驱动滚动请求，否则会形成“日志一条、列表一顿”的观感。
                guard messages.last?.role == .assistant else {
                    return
                }
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
                // 新活动批次或独立进度行出现时，只有用户原本贴底才继续跟随。
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
                    toggleActivityDetails(itemID: item.id, scrollAnchorID: item.id, proxy: proxy)
                }
            )
                .equatable()
        case .activityBatch(let group):
            ConversationActivityBatchRow(
                group: group,
                layout: layout,
                isExpanded: expandedActivityGroupIDs.contains(group.id),
                expandedActivityIDs: expandedActivityIDs,
                toggleGroup: {
                    toggleActivityGroup(groupID: group.id, proxy: proxy)
                },
                toggleActivity: { message in
                    toggleActivityDetails(
                        itemID: ConversationTimelineItem.activityID(for: message),
                        scrollAnchorID: group.id,
                        proxy: proxy
                    )
                }
            )
                .equatable()
        case .processGroup(let group):
            ConversationProcessGroupRow(
                group: group,
                layout: layout,
                isExpanded: expandedActivityGroupIDs.contains(group.id),
                expandedActivityIDs: expandedActivityIDs,
                toggleGroup: {
                    toggleActivityGroup(groupID: group.id, proxy: proxy)
                },
                toggleActivity: { message in
                    toggleActivityDetails(
                        itemID: ConversationTimelineItem.activityID(for: message),
                        scrollAnchorID: group.id,
                        proxy: proxy
                    )
                }
            )
            .equatable()
        }
    }

    private func toggleActivityDetails(
        itemID: String,
        scrollAnchorID: String,
        proxy: ScrollViewProxy
    ) {
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
                proxy.scrollTo(scrollAnchorID, anchor: .bottom)
            }
        }
    }

    private func toggleActivityGroup(groupID: String, proxy: ScrollViewProxy) {
        let isExpanding = !expandedActivityGroupIDs.contains(groupID)
        let updateExpansion = {
            if isExpanding {
                expandedActivityGroupIDs.insert(groupID)
            } else {
                expandedActivityGroupIDs.remove(groupID)
            }
        }
        if accessibilityReduceMotion {
            updateExpansion()
        } else {
            // 无回弹弹簧从当前呈现状态继续，连续点击时不会等待上一段动画结束。
            withAnimation(.spring(response: 0.32, dampingFraction: 1)) {
                updateExpansion()
            }
        }
        guard isExpanding, isTimelineNearBottom else {
            return
        }
        Task { @MainActor in
            await Task.yield()
            guard expandedActivityGroupIDs.contains(groupID) else {
                return
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(groupID, anchor: .bottom)
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
                isTailFollowLocked = false
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

    static func shouldScheduleTailFollowForNewTailMessage(_ message: ConversationMessage?) -> Bool {
        message?.role != .system
    }

    static func shouldAttemptTailScroll(
        force: Bool,
        shouldFollowMessageTail: Bool,
        forceNextMessageTailScroll: Bool,
        isTailFollowLocked: Bool,
        isTimelineNearBottom: Bool
    ) -> Bool {
        force ||
            shouldFollowMessageTail ||
            forceNextMessageTailScroll ||
            isTailFollowLocked ||
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
                    Label(L10n.text("ui.load_older_messages"), systemImage: "clock.arrow.circlepath")
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
        hasUnseenTailMessage ? L10n.text("ui.return_to_the_bottom_to_view_new_messages") : L10n.text("ui.back_to_latest_news")
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
                Text(L10n.text("ui.start_this_conversation"))
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(workbenchPrimaryText)
                Text(L10n.text("ui.enter_your_tasks_below_and_mimi_remote_retains"))
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
            ProgressView(L10n.text("ui.loading_session_records"))
                .accessibilityLabel(L10n.text("ui.loading_session_records"))
        } else if let error = sessionStore.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            ContentUnavailableView {
                Label(L10n.text("ui.session_record_loading_failed"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(L10n.text("ui.try_again")) {
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
            isTailFollowLocked: isTailFollowLocked,
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
            // 首次挂载、Markdown 排版和 List 快照可能分多个布局周期完成。长列表在
            // 高负载下会晚于首轮 1.3 秒重试才提交最终 contentSize，因此保留一次
            // 较晚的无动画重锚；用户一旦主动上翻，generation 检查会立刻停止后续滚动。
            for delay in [120_000_000, 320_000_000, 900_000_000, 1_800_000_000] as [UInt64] {
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
        isTailFollowLocked = true
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
