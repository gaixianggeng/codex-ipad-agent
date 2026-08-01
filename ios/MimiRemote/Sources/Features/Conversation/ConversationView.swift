import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    // 不同 iPadOS 侧栏形态下，detail 的 size 提案和 leading safe area 组合并不一致：
    // 有的版本给整窗宽度并把侧栏记在 safe area，有的已经缩小 size 却仍报告 inset，
    // 纯提案算术会把横屏详情列的宽度重复扣除侧栏而误入紧凑分支。
    // 内容真实排版宽度才是唯一可信来源，提案算术只用于测量到达前的首帧。
    @State private var measuredContentWidth: CGFloat?
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
            let layout = measuredContentWidth.map { width in
                ConversationLayout(
                    containerWidth: width,
                    horizontalSizeClass: horizontalSizeClass
                )
            } ?? ConversationLayout(
                containerWidth: proxy.size.width,
                horizontalSizeClass: horizontalSizeClass,
                safeAreaInsets: proxy.safeAreaInsets
            )
            let composerWidth = min(layout.composerAvailableWidth, layout.composerMaxWidth)

            VStack(spacing: 0) {
                topStatusStrip(model: model, layout: layout)
                ConversationTimelineView(layout: layout)
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { width in
                guard width > 0, measuredContentWidth != width else {
                    return
                }
                measuredContentWidth = width
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Spacer(minLength: 0)
                    ComposerView(
                        availableWidth: composerWidth,
                        initialGoalStatusExpanded: initialGoalStatusExpanded
                    )
                        // 确定宽度阻止固定尺寸的工具按钮反向撑大输入卡和上方目标栏。
                        .frame(width: composerWidth)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, layout.horizontalInset)
                .padding(.top, layout.composerTopPadding)
                .padding(.bottom, layout.composerBottomPadding)
                // 不再铺一层近实色 dock：安全区直接沿用会话主背景，只让 Composer
                // 自己承担唯一的功能材质层，底部视觉不会与消息系统切成两块。
            }
            .background(tokens.background.ignoresSafeArea())
            .task(id: sessionStore.selectedSession?.id) {
                await sessionStore.warmSelectedClaudeAuthentication()
            }
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
        Label(L10n.format("ui.error_value", message), systemImage: "exclamationmark.triangle")
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
            return L10n.format("ui.current_value_value", status.title, runtimeDisplay.detailText)
        }
        return L10n.format("ui.current_value", status.title)
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
                    await sessionStore.refreshSelectedUsage()
                }
            } label: {
                Label(L10n.text("ui.refresh_status"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(sessionStore.isRefreshingSelectedSession || sessionStore.isLoading)

            if notice.canDismiss {
                Button {
                    sessionStore.dismissErrorMessage()
                } label: {
                    Label(L10n.text("ui.close"), systemImage: "xmark.circle")
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
                    Label(L10n.text("ui.view_abbreviated_version_only"), systemImage: "text.justify")
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
                    Label(L10n.text("ui.retry_full_history"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(sessionStore.isRefreshingSelectedSession)

                Button {
                    Task {
                        await sessionStore.loadSummaryHistoryForSelectedSession()
                    }
                } label: {
                    Label(L10n.text("ui.view_abbreviated_version_only"), systemImage: "text.justify")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(sessionStore.isRefreshingSelectedSession)

            case .loadingSummary:
                Button {} label: {
                    Label(L10n.text("ui.loading_3667cb10"), systemImage: "hourglass")
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
                    Label(L10n.text("ui.load_full_history"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(sessionStore.isRefreshingSelectedSession)

                Button {
                    sessionStore.dismissSelectedHistorySavingsNotice()
                } label: {
                    Label(L10n.text("ui.close"), systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

            case .summaryFailed:
                Button {
                    Task {
                        await sessionStore.loadSummaryHistoryForSelectedSession()
                    }
                } label: {
                    Label(L10n.text("ui.try_again_abbreviated_version"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(sessionStore.isRefreshingSelectedSession)

                Button {
                    sessionStore.dismissSelectedHistorySavingsNotice()
                } label: {
                    Label(L10n.text("ui.close"), systemImage: "xmark.circle")
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
