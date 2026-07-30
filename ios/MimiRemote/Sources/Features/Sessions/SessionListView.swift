import SwiftUI

enum SessionIndexRowStyle {
    case sidebar
    case library
}

struct SessionRuntimePresentation: Equatable {
    enum Kind: Equatable {
        case codex
        case claude
    }

    let kind: Kind

    init(session: AgentSession) {
        self.init(runtimeProvider: session.runtimeProvider, source: session.source)
    }

    init(runtimeProvider: String?, source: String) {
        let provider = runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = provider?.isEmpty == false ? provider : source
        kind = CodexAppServerSessionRuntime.normalizedRuntimeProvider(rawValue) == "claude"
            ? .claude
            : .codex
    }

    var title: String {
        switch kind {
        case .codex:
            return L10n.text("ui.runtime_default")
        case .claude:
            return L10n.text("ui.runtime_optional")
        }
    }

    var brandAssetName: String {
        switch kind {
        case .codex:
            return "ChatGPT"
        case .claude:
            return "Claude"
        }
    }
}

/// 会话列表里的运行时标识使用中性胶囊承载品牌图标和名称。
/// 它需要比普通元数据更容易扫读，但不能抢过会话标题和需要处理的状态。
struct SessionRuntimeBadge: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let presentation: SessionRuntimePresentation
    var compact = false

    init(session: AgentSession, compact: Bool = false) {
        presentation = SessionRuntimePresentation(session: session)
        self.compact = compact
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let iconSize: CGFloat = compact ? 10 : 12

        HStack(spacing: compact ? 3 : 4) {
            Image(presentation.brandAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)

            Text(presentation.title)
                .lineLimit(1)
        }
        .font(themeStore.uiFont(size: compact ? 9 : 10, weight: .medium))
        .foregroundStyle(tokens.secondaryText)
        .padding(.horizontal, compact ? 5 : 6)
        .padding(.vertical, compact ? 1.5 : 2)
        .background(tokens.elevatedSurface.opacity(0.76), in: Capsule())
        .overlay {
            Capsule()
                .stroke(tokens.border.opacity(0.54), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.title)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// 置顶属于用户主动设置的稳定状态，用品牌紫实底与白色钉子提升扫读辨识度。
/// 组件统一服务规划 Tab、工作区最近规划和侧栏，避免三个入口各自使用不同强调方式。
struct SessionPinnedBadge: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var compact = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let side: CGFloat = compact ? 17 : 20

        Image(systemName: "pin.fill")
            .font(themeStore.uiFont(size: compact ? 8 : 10, weight: .bold))
            .foregroundStyle(tokens.primaryActionForeground)
            .frame(width: side, height: side)
            .background(
                tokens.primaryAction,
                in: RoundedRectangle(cornerRadius: compact ? 5 : 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 5 : 6, style: .continuous)
                    .stroke(tokens.primaryActionForeground.opacity(0.18), lineWidth: 0.5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("ui.pinned"))
            .fixedSize()
    }
}

/// 会话索引只用品牌图标表达运行时身份，避免名称胶囊和标题争夺横向空间。
/// 尺寸由使用方传入，以便与同一行的 Git 图标保持一致；运行态保留品牌色，
/// 历史态统一降为灰色，让颜色只承担“仍在进行”的状态提示。
struct SessionRuntimeIcon: View {
    let presentation: SessionRuntimePresentation
    let size: CGFloat
    let isActive: Bool

    init(session: AgentSession, size: CGFloat, isActive: Bool) {
        presentation = SessionRuntimePresentation(session: session)
        self.size = size
        self.isActive = isActive
    }

    var body: some View {
        Image(presentation.brandAssetName)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: renderedSize, height: renderedSize)
            .frame(width: size, height: size)
            .grayscale(isActive ? 0 : 1)
            .opacity(isActive ? 0.92 : 0.46)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.title)
            .fixedSize()
    }

    private var renderedSize: CGFloat {
        switch presentation.kind {
        case .codex:
            // ChatGPT 位图自带透明内边距；只放大图形，不扩大元数据行的布局占位。
            return size * 1.35
        case .claude:
            return size
        }
    }
}

/// 使用 Codex 与 Claude Code 桌面端都采用的经典三节点分支拓扑。
/// 自绘可以避免 SF Symbol 的三角轮廓，同时维持小尺寸下的圆角描边与清晰度。
struct SessionBranchIcon: View {
    let size: CGFloat

    var body: some View {
        SessionBranchGlyph()
            .stroke(
                style: StrokeStyle(
                    lineWidth: max(0.75, size * 0.08125),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: size, height: size)
            .fixedSize()
    }
}

private struct SessionBranchGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2
        )
        let point: (CGFloat, CGFloat) -> CGPoint = { x, y in
            CGPoint(x: origin.x + side * x, y: origin.y + side * y)
        }
        let nodeRadius = side * 0.11875
        let upperNode = point(0.296875, 0.234375)
        let lowerNode = point(0.296875, 0.765625)
        let branchNode = point(0.75, 0.65625)

        var path = Path()
        for center in [upperNode, lowerNode, branchNode] {
            path.addEllipse(
                in: CGRect(
                    x: center.x - nodeRadius,
                    y: center.y - nodeRadius,
                    width: nodeRadius * 2,
                    height: nodeRadius * 2
                )
            )
        }

        path.move(to: point(0.296875, 0.353125))
        path.addLine(to: point(0.296875, 0.646875))
        path.move(to: point(0.296875, 0.40625))
        path.addCurve(
            to: point(0.63125, 0.65625),
            control1: point(0.296875, 0.5875),
            control2: point(0.44375, 0.65625)
        )
        return path
    }
}

enum SessionLibraryStatusFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case needsAttention
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L10n.text("ui.all_status")
        case .active: return L10n.text("ui.running")
        case .needsAttention: return L10n.text("ui.need_to_be_processed")
        case .history: return L10n.text("ui.history")
        }
    }

    func includes(_ session: AgentSession) -> Bool {
        switch self {
        case .all:
            return true
        case .active:
            return session.isRunning
        case .needsAttention:
            return session.status == SessionStatus.waitingForApproval.rawValue ||
                session.status == SessionStatus.waitingForInput.rawValue ||
                session.pendingApproval != nil ||
                session.pendingUserInput != nil ||
                session.status == SessionStatus.failed.rawValue
        case .history:
            return !session.isRunning
        }
    }
}

/// 会话生命周期是列表的第一层信息。保持输入顺序，只负责把仍在进行的任务和历史记录分开。
struct SessionListPartition: Equatable {
    let active: [AgentSession]
    let history: [AgentSession]

    init(sessions: [AgentSession]) {
        active = sessions.filter(\.isRunning)
        history = sessions.filter { !$0.isRunning }
    }
}

/// 完整会话库只展示轻量索引；消息历史仍在用户选中会话后按需加载。
struct SessionListView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedWorkspaceID = "all"
    @State private var selectedStatus: SessionLibraryStatusFilter = .all

    var onNewSession: (() -> Void)?
    var onSelectSession: ((AgentSession) -> Void)?
    var manageConnections: (() -> Void)?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        List {
            if visibleSessions.isEmpty && !sessionStore.isLoading {
                if sessionStore.isSessionSearchActive && sessionStore.isSearchingRemoteSessionResults {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(L10n.text("ui.searching_historical_conversations"))
                            .font(themeStore.uiFont(size: 13, weight: .medium))
                            .foregroundStyle(tokens.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .accessibilityIdentifier("sessions.search.initialLoading")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ContentUnavailableView {
                        Label(L10n.text("ui.no_matching_session"), systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text(sessionStore.isSessionSearchActive ? L10n.text("ui.try_changing_keywords_or_filter_conditions") : L10n.text("ui.new_sessions_created_from_a_workspace_appear_here"))
                    } actions: {
                        Button(L10n.text("ui.new_session"), action: presentNewSession)
                            .buttonStyle(.borderedProminent)
                            .tint(tokens.primaryAction)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } else {
                if !sessionPartition.active.isEmpty {
                    Section {
                        sessionRows(sessionPartition.active)
                    } header: {
                        sessionSectionHeader(
                            title: L10n.text("ui.in_progress"),
                            systemImage: "bolt.fill",
                            count: sessionPartition.active.count,
                            color: tokens.primaryAction
                        )
                    }
                }

                if !sessionPartition.history.isEmpty {
                    Section {
                        sessionRows(sessionPartition.history)
                    } header: {
                        sessionSectionHeader(
                            title: L10n.text("ui.history"),
                            systemImage: "clock.arrow.circlepath",
                            count: sessionPartition.history.count,
                            color: tokens.tertiaryText
                        )
                    }
                }
            }

            // Gateway 过滤后当前页可能没有可见结果但仍给出 nextCursor，入口必须独立于空态展示。
            if sessionStore.isSessionSearchActive && sessionStore.sessionSearchHasMore {
                Button {
                    Task { await sessionStore.loadMoreSessionSearchResults() }
                } label: {
                    HStack(spacing: 8) {
                        if sessionStore.isLoadingMoreSessionSearchResults {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text(sessionStore.isLoadingMoreSessionSearchResults ? L10n.text("ui.searching_continues") : L10n.text("ui.continue_searching"))
                    }
                    .font(themeStore.uiFont(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.secondaryText)
                .disabled(sessionStore.isLoadingMoreSessionSearchResults)
                .accessibilityIdentifier("sessions.search.loadMore")
                .listRowInsets(.init(top: 4, leading: 20, bottom: 8, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle(L10n.text("ui.session"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $sessionStore.sessionSearchQuery, placement: .navigationBarDrawer(displayMode: .automatic), prompt: L10n.text("ui.search_session"))
        .toolbar {
            if let manageConnections {
                ToolbarItem(placement: .topBarLeading) {
                    HostSwitcherMenu(
                        presentation: .toolbar,
                        manageConnections: manageConnections
                    )
                }
                // 全局 Mac 入口与列表筛选是不同作用域，固定间隔让系统分别生成圆形材质。
                ToolbarSpacer(.fixed, placement: .topBarLeading)
            }
            ToolbarItem(placement: .topBarLeading) {
                filterMenu(tokens: tokens)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                sessionListToolbarButton(
                    systemImage: "arrow.clockwise",
                    accessibilityLabel: L10n.text("ui.refresh_session_library"),
                    tokens: tokens
                ) {
                    Task { await sessionStore.refreshSessionLibraryIndex(authoritative: true) }
                }

                sessionListToolbarButton(
                    systemImage: "plus",
                    accessibilityLabel: L10n.text("ui.new_session_3da224c4"),
                    tokens: tokens,
                    isPrimary: true,
                    action: presentNewSession
                )
                .accessibilityIdentifier("sessions.newSession")
            }
        }
        .task {
            await sessionStore.refreshSessionLibraryIndex()
        }
    }

    /// 使用系统工具栏按钮，让不同系统版本自行处理材质、按下反馈和命中区域。
    private func sessionListToolbarButton(
        systemImage: String,
        accessibilityLabel: String,
        tokens: ThemeTokens,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 15, weight: .semibold))
        }
        // 顶部导航保留品牌紫；工具栏仅靠明度区分主次，避免刷新与新建重复着色。
        .foregroundStyle(isPrimary ? tokens.primaryText : tokens.secondaryText)
        .tint(tokens.secondaryText)
        .accessibilityLabel(accessibilityLabel)
    }

    private var visibleSessions: [AgentSession] {
        sessionStore.sessionLibrarySessions.filter { session in
            (selectedWorkspaceID == "all" || session.projectID == selectedWorkspaceID) &&
                selectedStatus.includes(session)
        }
    }

    private var sessionPartition: SessionListPartition {
        SessionListPartition(sessions: visibleSessions)
    }

    @ViewBuilder
    private func sessionRows(_ sessions: [AgentSession]) -> some View {
        ForEach(sessions) { session in
            SessionIndexRow(
                session: session,
                foregroundActivity: sessionStore.foregroundActivity(for: session.id),
                isSelected: session.id == sessionStore.selectedSessionID,
                isPinned: sessionStore.isSessionPinned(session.id),
                isArchived: sessionStore.isSessionArchived(session.id),
                reminder: sessionStore.sessionReminder(for: session.id),
                isObserving: sessionStore.isSessionObserving(session),
                isExternalReadOnly: sessionStore.isExternalReadOnlySession(session),
                style: .library,
                searchSnippet: sessionStore.sessionSearchSnippet(for: session.id)
            )
            .contentShape(Rectangle())
            .onTapGesture { select(session) }
            .accessibilityIdentifier("sessions.row.\(session.id)")
            .sessionRowActions(session)
            .listRowInsets(.init(top: 4, leading: 20, bottom: 4, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    private func sessionSectionHeader(
        title: String,
        systemImage: String,
        count: Int,
        color: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(color.opacity(0.72))
        }
        .font(themeStore.uiFont(.caption, weight: .semibold))
        .foregroundStyle(color)
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }

    private func filterMenu(tokens: ThemeTokens) -> some View {
        Menu {
            Section(L10n.text("ui.workspace")) {
                Button {
                    selectedWorkspaceID = "all"
                } label: {
                    Label(L10n.text("ui.all_workspaces"), systemImage: selectedWorkspaceID == "all" ? "checkmark" : "folder")
                }
                ForEach(sessionStore.sidebarProjects) { project in
                    Button {
                        selectedWorkspaceID = project.id
                    } label: {
                        Label(project.name, systemImage: selectedWorkspaceID == project.id ? "checkmark" : "folder")
                    }
                }
            }
            Section(L10n.text("ui.status")) {
                ForEach(SessionLibraryStatusFilter.allCases) { filter in
                    Button {
                        selectedStatus = filter
                    } label: {
                        Label(filter.title, systemImage: selectedStatus == filter ? "checkmark" : "line.3.horizontal.decrease.circle")
                    }
                }
            }
        } label: {
            Label(filterTitle, systemImage: "line.3.horizontal.decrease")
                .foregroundStyle(tokens.secondaryText)
        }
        .accessibilityLabel(L10n.text("ui.filter_sessions"))
    }

    private var filterTitle: String {
        if selectedWorkspaceID != "all",
           let project = sessionStore.sidebarProjects.first(where: { $0.id == selectedWorkspaceID }) {
            return project.name
        }
        return selectedStatus == .all ? L10n.text("ui.filter") : selectedStatus.title
    }

    private func presentNewSession() {
        if let onNewSession {
            onNewSession()
        } else {
            Task { await sessionStore.startNewSession() }
        }
    }

    private func select(_ session: AgentSession) {
        if let onSelectSession {
            onSelectSession(session)
        } else {
            Task { await sessionStore.selectSession(session) }
        }
    }
}

struct SessionIndexRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let session: AgentSession
    let foregroundActivity: SessionForegroundActivity?
    let isSelected: Bool
    let isPinned: Bool
    let isArchived: Bool
    let reminder: SessionReminder?
    let isObserving: Bool
    let isExternalReadOnly: Bool
    let style: SessionIndexRowStyle
    var searchSnippet: String? = nil

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: style == .sidebar ? 3 : 7) {
            HStack(alignment: .center, spacing: 7) {
                Text(session.title)
                    .font(themeStore.uiFont(size: style == .sidebar ? 14 : 16, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                if style == .library {
                    Text(timestampText)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.tertiaryText)
                        .fixedSize()
                }
            }

            HStack(spacing: 6) {
                if isPinned {
                    SessionPinnedBadge(compact: style == .sidebar)
                }
                if isArchived { Image(systemName: "archivebox.fill") }
                if reminder != nil { Image(systemName: "bell.fill").foregroundStyle(tokens.warning) }

                SessionRuntimeIcon(
                    session: session,
                    size: style == .sidebar ? 8 : 10,
                    isActive: session.isRunning
                )

                if isExternalReadOnly {
                    Text(L10n.text("ui.mac_observe_only"))
                        .font(themeStore.uiFont(size: style == .sidebar ? 9 : 11, weight: .semibold))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if let branch = session.gitBranchName {
                    HStack(spacing: 3) {
                        // Git 是会话元数据而非身份标识，使用中性色避免和 AI 品牌图标竞争。
                        SessionBranchIcon(size: style == .sidebar ? 8 : 10)
                            .foregroundStyle(tokens.tertiaryText)
                            .accessibilityHidden(true)

                        Text(branch)
                            .foregroundStyle(tokens.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: style == .sidebar ? 100 : 150, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(L10n.text("ui.branch")) \(branch)")
                }

                // “历史”已经由列表分区表达；只有实时、异常或其他有区分度的状态才进入行内。
                if shouldShowStatusLabel {
                    statusLabel(tokens: tokens)
                }

                if isObserving {
                    Image(systemName: "eye")
                        .foregroundStyle(tokens.tertiaryText)
                        .accessibilityLabel(L10n.text("ui.just_observe"))
                }

                Spacer(minLength: style == .sidebar ? 4 : 10)

                // 项目归属固定在尾部，长分支只压缩自身，不再带着项目名左右漂移。
                HStack(spacing: style == .sidebar ? 4 : 6) {
                    Text(session.project.isEmpty ? session.dir : session.project)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: style == .sidebar ? 88 : 160, alignment: .trailing)

                    if style == .sidebar {
                        Text("·")
                        Text(timestampText)
                    }
                }
                .layoutPriority(1)
            }
            .font(themeStore.uiFont(size: style == .sidebar ? 10 : 12, weight: .regular))
            .foregroundStyle(tokens.tertiaryText)
            .lineLimit(1)

            if style == .library,
               let searchSnippet,
               !searchSnippet.isEmpty {
                Text(searchSnippet)
                    .font(themeStore.uiFont(size: 12, weight: .regular))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, style == .sidebar ? 10 : 14)
        .padding(.vertical, style == .sidebar ? 6 : 12)
        // 视觉仍保持紧凑，但整个会话行至少保留 44pt，兼顾触控、指针和全键盘访问。
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(rowBackground(tokens: tokens), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(tokens.primaryAction)
                    .frame(width: 3)
                    .padding(.vertical, 9)
                    .padding(.leading, 2)
            }
        }
        .overlay {
            if style == .library {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(rowBorder(tokens: tokens), lineWidth: 1)
            }
        }
    }

    private var status: AgentSessionDisplayStatus {
        return session.displayStatus(foregroundActivity: foregroundActivity)
    }

    private var shouldShowStatusLabel: Bool {
        !(session.status == SessionStatus.history.rawValue && status.tone == .neutral)
    }

    @ViewBuilder
    private func statusLabel(tokens: ThemeTokens) -> some View {
        HStack(spacing: 4) {
            if status.showsSpinner {
                ProgressView()
                    .controlSize(.mini)
                    .tint(statusColor(tokens: tokens))
            } else {
                Image(systemName: status.systemImage)
                    .font(themeStore.uiFont(size: style == .sidebar ? 8 : 10, weight: .semibold))
            }
            Text(status.title)
        }
        .font(themeStore.uiFont(size: style == .sidebar ? 9 : 11, weight: .semibold))
        .foregroundStyle(statusColor(tokens: tokens))
        .padding(.horizontal, style == .sidebar ? 0 : 7)
        .padding(.vertical, style == .sidebar ? 0 : 3)
        .background {
            if style == .library {
                Capsule()
                    .fill(statusColor(tokens: tokens).opacity(status.tone == .neutral ? 0.07 : 0.10))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.title)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func rowBackground(tokens: ThemeTokens) -> Color {
        if isSelected {
            return tokens.selectionFill
        }
        guard style == .library else {
            return .clear
        }
        // 会话库行与输入面板使用同一层暖石墨填充；运行状态交给图标和标签表达，
        // 不再用大面积紫色/状态色染底。
        return tokens.contentPanelBackground
    }

    private func rowBorder(tokens: ThemeTokens) -> Color {
        if isSelected {
            return tokens.primaryAction.opacity(0.34)
        }
        if session.isRunning {
            return statusColor(tokens: tokens).opacity(0.24)
        }
        return tokens.border.opacity(0.58)
    }

    private func statusColor(tokens: ThemeTokens) -> Color {
        switch status.tone {
        case .active: return tokens.secondaryText
        case .warning: return tokens.warning
        case .danger: return .red
        case .complete, .neutral: return tokens.tertiaryText
        }
    }

    private var timestampText: String {
        guard let date = session.recencyAt ?? session.updatedAt ?? session.createdAt else { return "" }
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        return Self.dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("Hm")
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter
    }()
}

private enum SessionReviewScope: String, CaseIterable, Identifiable {
    case uncommittedChanges
    case baseBranch
    case commit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uncommittedChanges: return L10n.text("ui.changes_not_committed")
        case .baseBranch: return L10n.text("ui.relative_base_branch")
        case .commit: return L10n.text("ui.specify_submission")
        }
    }

    var systemImage: String {
        switch self {
        case .uncommittedChanges: return "pencil.and.list.clipboard"
        case .baseBranch: return "arrow.triangle.branch"
        case .commit: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

struct SessionReviewSheet: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let session: AgentSession
    @State private var scope: SessionReviewScope = .uncommittedChanges
    @State private var baseBranch = ""
    @State private var commitSHA = ""
    @State private var isSubmitting = false
    @State private var submissionError: String?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            Form {
                Section(L10n.text("ui.review_goals")) {
                    Picker(L10n.text("ui.target_type"), selection: $scope) {
                        ForEach(SessionReviewScope.allCases) { option in
                            Label(option.title, systemImage: option.systemImage)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                }

                switch scope {
                case .uncommittedChanges:
                    Section {
                        Label(L10n.text("ui.review_all_uncommitted_changes_in_the_current_workspace"), systemImage: "info.circle")
                            .foregroundStyle(tokens.secondaryText)
                    }
                case .baseBranch:
                    Section {
                        TextField(L10n.text("ui.for_example_main"), text: $baseBranch)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit(submit)
                            .accessibilityIdentifier("sessions.review.baseBranch")
                    } header: {
                        Text(L10n.text("ui.base_branch"))
                    } footer: {
                        Text(normalizedBaseBranch.isEmpty ? L10n.text("ui.please_enter_a_non_empty_branch_name") : L10n.format("ui.the_current_branch_will_be_reviewed_for_differences", normalizedBaseBranch))
                            .foregroundStyle(normalizedBaseBranch.isEmpty ? tokens.warning : tokens.tertiaryText)
                    }
                case .commit:
                    Section {
                        TextField(L10n.text("ui.commit_sha"), text: $commitSHA)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit(submit)
                            .accessibilityIdentifier("sessions.review.commit")
                    } header: {
                        Text(L10n.text("ui.submit"))
                    } footer: {
                        Text(normalizedCommitSHA.isEmpty ? L10n.text("ui.please_enter_a_non_empty_commit_sha") : L10n.format("ui.only_submission_value_will_be_reviewed", normalizedCommitSHA))
                            .foregroundStyle(normalizedCommitSHA.isEmpty ? tokens.warning : tokens.tertiaryText)
                    }
                }

                Section {
                    Label(L10n.text("ui.review_is_always_executed_within_the_current_session"), systemImage: "lock.shield")
                        .foregroundStyle(tokens.tertiaryText)
                }

                if let submissionError {
                    Section {
                        Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(tokens.warning)
                    }
                }
            }
            .font(themeStore.uiFont(.body))
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            .navigationTitle(L10n.text("ui.start_code_review"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(L10n.text("ui.start"))
                        }
                    }
                    .disabled(isSubmitting || session.isRunning || normalizedTarget == nil)
                    .accessibilityIdentifier("sessions.review.submit")
                }
            }
        }
        .tint(tokens.primaryAction)
        .interactiveDismissDisabled(isSubmitting)
        .presentationDetents([.medium, .large])
    }

    private var normalizedBaseBranch: String {
        baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedCommitSHA: String {
        commitSHA.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedTarget: CodexAppServerReviewTarget? {
        switch scope {
        case .uncommittedChanges:
            return .uncommittedChanges
        case .baseBranch:
            guard !normalizedBaseBranch.isEmpty else { return nil }
            return .baseBranch(normalizedBaseBranch)
        case .commit:
            guard !normalizedCommitSHA.isEmpty else { return nil }
            return .commit(sha: normalizedCommitSHA)
        }
    }

    private func submit() {
        guard !isSubmitting, !session.isRunning, let target = normalizedTarget else { return }
        isSubmitting = true
        submissionError = nil
        Task {
            let didStart = await sessionStore.startReview(session, target: target)
            isSubmitting = false
            if didStart {
                dismiss()
            } else {
                submissionError = sessionStore.statusMessage ?? L10n.text("ui.review_failed_to_start_please_try_again_later")
            }
        }
    }
}

struct SessionRenameSheet: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(\.dismiss) private var dismiss

    let session: AgentSession
    @State private var name: String
    @State private var isSaving = false

    init(session: AgentSession) {
        self.session = session
        _name = State(initialValue: session.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("ui.session_name")) {
                    TextField(L10n.text("ui.enter_name"), text: $name)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .onSubmit(save)
                }
            }
            .navigationTitle(L10n.text("ui.rename_session"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? L10n.text("ui.saving_6644f061") : L10n.text("ui.save"), action: save)
                        .disabled(isSaving || normalizedName.isEmpty || normalizedName == session.title)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !isSaving, !normalizedName.isEmpty else { return }
        isSaving = true
        Task {
            let didRename = await sessionStore.renameSession(session, name: normalizedName)
            isSaving = false
            if didRename {
                dismiss()
            }
        }
    }
}
