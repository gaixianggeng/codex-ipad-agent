import SwiftUI

enum WorkspaceSessionRuntimeChoice: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var runtimeProvider: String? {
        switch self {
        case .codex:
            return nil
        case .claude:
            return "claude"
        }
    }

    var title: String {
        switch self {
        case .codex:
            return L10n.text("ui.create_a_new_codex_session")
        case .claude:
            return L10n.text("ui.create_a_new_claude_code_session")
        }
    }

    /// 商店版本只使用系统符号表达运行时类型。
    /// 第三方产品名称可用于兼容性说明，但不把第三方商标图标打包成 Mimi 的品牌资产。
    var systemImageName: String {
        switch self {
        case .codex:
            return "terminal.fill"
        case .claude:
            return "sparkles"
        }
    }

    static func available(claudeChannelAvailable: Bool) -> [Self] {
        claudeChannelAvailable ? [.codex, .claude] : [.codex]
    }
}

enum WorkspaceStripLayout {
    static let horizontalPadding: CGFloat = 24
    // 316pt 能给路径、状态和两组统计留下稳定空间，同时在 iPad 上仍能露出相邻卡片，提示可横向滚动。
    static let cardWidth: CGFloat = 316
    static let stripHeight: CGFloat = 166

    static func minimumContentWidth(viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - horizontalPadding * 2)
    }
}

/// 工作区只维护本地浏览选择。只有用户明确进入会话或新建会话时，才交给 SessionStore 改变活动上下文。
struct WorkspaceRootView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let onStartSession: (AgentProject, WorkspaceSessionRuntimeChoice) -> Void
    let onOpenSession: (AgentSession) -> Void
    let embedsNavigationStack: Bool

    @State private var selectedWorkspaceID: String?
    @State private var catalogState: CatalogState = .idle
    @State private var sessionLoadStates: [String: WorkspaceSessionLoadState] = [:]
    @State private var isPresentingOpenWorkspace = false
    @State private var pendingWorkspaceRemoval: AgentProject?

    init(
        onStartSession: @escaping (AgentProject, WorkspaceSessionRuntimeChoice) -> Void,
        onOpenSession: @escaping (AgentSession) -> Void = { _ in },
        embedsNavigationStack: Bool = true
    ) {
        self.onStartSession = onStartSession
        self.onOpenSession = onOpenSession
        self.embedsNavigationStack = embedsNavigationStack
    }

    static func shouldEmbedNavigationStack(usesCompactNavigation: Bool) -> Bool {
        // 紧凑布局的 destination 已经在根导航栈内；只有独立/宽屏入口需要自己建栈。
        !usesCompactNavigation
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if embedsNavigationStack {
                NavigationStack {
                    navigationContent(tokens: tokens)
                }
            } else {
                // iPhone 紧凑布局已由 UnifiedWorkbenchShell 持有绑定 path 的导航栈。
                // 这里再嵌套 NavigationStack 会让 SwiftUI 在首次打开工作区时同时重算两层导航状态。
                navigationContent(tokens: tokens)
            }
        }
        .task {
            synchronizeSelection()
            // 每次进入工作区都做轻量目录同步，同时执行旧版自动候选数据清理；
            // 该请求不改变当前会话和 WebSocket，上层选择保持稳定。
            await refreshCatalog()
            synchronizeSelection()
        }
        .task {
            // 两个新建入口先稳定渲染；Claude 通道能力独立在后台刷新，不能让网络往返
            // 决定按钮何时才出现在布局里。
            await sessionStore.refreshAppServerModelOptions()
        }
        .task(id: selectedWorkspaceID) {
            guard let selectedWorkspaceID else { return }
            // 首次进入或切换工作区时，如果本地还没有数据就主动补齐会话首屏。
            // 已有内容时保留即时展示，用户仍可通过刷新按钮或下拉手动同步。
            guard sessionStore.sessions(forProjectID: selectedWorkspaceID).isEmpty else {
                sessionLoadStates[selectedWorkspaceID] = .loaded
                return
            }
            await refreshWorkspaceSessions(projectID: selectedWorkspaceID)
        }
        .onChange(of: sessionStore.sidebarProjects.map(\.id)) { _, _ in
            synchronizeSelection()
            if !sessionStore.sidebarProjects.isEmpty {
                catalogState = .loaded
            }
        }
        .sheet(isPresented: $isPresentingOpenWorkspace) {
            OpenWorkspaceSheet { workspaceID in
                // 工作区页使用本地浏览选择；Sheet 成功打开目录后要显式切到新工作区，
                // 不能依赖全局 selectedProjectID，否则会破坏浏览选择与会话上下文的解耦。
                selectedWorkspaceID = workspaceID
            }
        }
        .confirmationDialog(
            L10n.text("ui.remove_directory"),
            isPresented: Binding(
                get: { pendingWorkspaceRemoval != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingWorkspaceRemoval = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let project = pendingWorkspaceRemoval {
                Button(L10n.format("ui.remove_directory_value", project.name), role: .destructive) {
                    removeWorkspace(project)
                }
            }
            Button(L10n.text("ui.cancel"), role: .cancel) {
                pendingWorkspaceRemoval = nil
            }
        } message: {
            Text(L10n.text("ui.removing_a_directory_only_removes_it_from_the_workspace"))
        }
        .background(tokens.background.ignoresSafeArea())
    }

    private func navigationContent(tokens: ThemeTokens) -> some View {
        workspaceBrowser(tokens: tokens)
            .navigationTitle(L10n.text("ui.workspace"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresentingOpenWorkspace = true
                    } label: {
                        Label(L10n.text("ui.open_directory"), systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(tokens.primaryAction)
                }
            }
    }

    @ViewBuilder
    private func workspaceBrowser(tokens: ThemeTokens) -> some View {
        if sessionStore.sidebarProjects.isEmpty {
            if catalogState == .loading {
                workspaceLoadingState(tokens: tokens)
            } else {
                workspaceEmptyState(tokens: tokens)
            }
        } else {
            VStack(spacing: 0) {
                workspaceStrip(tokens: tokens)

                Divider()
                    .overlay(tokens.border.opacity(0.7))

                if let selectedProject {
                    workspaceDetail(project: selectedProject)
                        .id(selectedProject.id)
                        .refreshable {
                            await refreshWorkspaceContent(projectID: selectedProject.id)
                        }
                } else {
                    ContentUnavailableView(L10n.text("ui.please_select_a_workspace"), systemImage: "folder")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(tokens.background.ignoresSafeArea())
        }
    }

    private func workspaceLoadingState(tokens: ThemeTokens) -> some View {
        VStack(spacing: 0) {
            workspaceStrip(tokens: tokens)

            Divider()
                .overlay(tokens.border.opacity(0.7))

            ProgressView(L10n.text("ui.loading_workspace"))
                .font(themeStore.uiFont(.callout, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
                .tint(tokens.primaryAction)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(tokens.background.ignoresSafeArea())
        .accessibilityIdentifier("workspace.loadingState")
    }

    private func workspaceEmptyState(tokens: ThemeTokens) -> some View {
        let isFailure: Bool
        if case .failed = catalogState {
            isFailure = true
        } else {
            isFailure = false
        }
        let tint = isFailure ? tokens.warning : tokens.primaryAction

        return VStack(spacing: 0) {
            Spacer(minLength: 40)

            VStack(spacing: 18) {
                Image(systemName: emptyWorkspaceSymbol)
                    .font(themeStore.uiFont(size: 28, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(width: 64, height: 64)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(spacing: 7) {
                    Text(emptyWorkspaceTitle)
                        .font(themeStore.uiFont(.title3, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)

                    Text(emptyWorkspaceMessage)
                        .font(themeStore.uiFont(.callout))
                        .foregroundStyle(tokens.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }

                Button {
                    if isFailure {
                        Task { await refreshCatalog() }
                    } else {
                        isPresentingOpenWorkspace = true
                    }
                } label: {
                    Label(isFailure ? L10n.text("ui.reload") : L10n.text("ui.open_directory"), systemImage: isFailure ? "arrow.clockwise" : "folder.badge.plus")
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(tokens.primaryAction)
                .accessibilityIdentifier("workspace.emptyAction")
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 32)
            .padding(.vertical, 36)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.background.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.emptyState")
    }

    private func workspaceStrip(tokens: ThemeTokens) -> some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        if catalogState == .loading && sessionStore.sidebarProjects.isEmpty {
                            ForEach(0..<4, id: \.self) { index in
                                WorkspaceLibraryCard(
                                    project: AgentProject(id: "loading-\(index)", name: L10n.text("ui.loading_workspace"), path: "/Users/you/code/project"),
                                    sessionCount: 0,
                                    worktreeCount: 0,
                                    isUnavailable: false,
                                    isSelected: false,
                                    tokens: tokens,
                                    action: {},
                                    onRemove: {}
                                )
                                .frame(width: WorkspaceStripLayout.cardWidth)
                                .redacted(reason: .placeholder)
                            }
                        } else {
                            ForEach(sessionStore.sidebarProjects) { project in
                                WorkspaceLibraryCard(
                                    project: project,
                                    sessionCount: sessionStore.sessions(forProjectID: project.id).count,
                                    worktreeCount: sessionStore.managedWorktrees(rootProjectID: sessionStore.rootProjectID(forProjectID: project.id)).count,
                                    isUnavailable: sessionStore.isWorkspaceUnavailable(project.id),
                                    isSelected: selectedWorkspaceID == project.id,
                                    tokens: tokens
                                ) {
                                    // 工作区页面只更新本地浏览选择，避免切换卡片时意外改变当前会话上下文。
                                    selectedWorkspaceID = project.id
                                } onRemove: {
                                    // 当前浏览中的卡片不允许移除；用户需先切到正确工作区，再处理误开的目录。
                                    guard selectedWorkspaceID != project.id else { return }
                                    pendingWorkspaceRemoval = project
                                }
                                .frame(width: WorkspaceStripLayout.cardWidth)
                                .id(project.id)
                            }
                        }
                    }
                    // 少量卡片作为一个组居中；卡片较多时 LazyHStack 按固有宽度增长，
                    // 仍保持正常横向滚动和选中项定位。
                    .frame(
                        minWidth: WorkspaceStripLayout.minimumContentWidth(viewportWidth: geometry.size.width),
                        alignment: .center
                    )
                    .padding(.horizontal, WorkspaceStripLayout.horizontalPadding)
                    .padding(.vertical, 14)
                }
            }
            .frame(height: WorkspaceStripLayout.stripHeight)
            .onChange(of: selectedWorkspaceID) { _, selectedID in
                guard let selectedID else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
            .onAppear {
                guard let selectedWorkspaceID else { return }
                // 恢复已有选择时主动定位卡片，保证选中项不会留在横向列表的屏幕外。
                DispatchQueue.main.async {
                    proxy.scrollTo(selectedWorkspaceID, anchor: .center)
                }
            }
        }
        .accessibilityLabel(L10n.text("ui.workspace_list"))
    }

    private func workspaceDetail(project: AgentProject) -> some View {
        let loadState = sessionLoadState(for: project.id)
        return WorkspaceDetailView(
            // 工作区详情承担完整历史浏览，展示所有已加载页；项目侧栏才保留 5 条预览窗口。
            recentSessions: sessionStore.sessions(forProjectID: project.id),
            sessionLoadState: loadState,
            canLoadMoreSessions: sessionStore.canLoadMoreSessions(projectID: project.id),
            claudeChannelAvailable: sessionStore.hasClaudeRuntimeChannel,
            onRefreshSessions: {
                Task {
                    await refreshWorkspaceSessions(projectID: project.id)
                }
            },
            onLoadMoreSessions: {
                await sessionStore.loadMoreSessions(projectID: project.id)
            },
            onStartSession: { runtimeChoice in
                onStartSession(project, runtimeChoice)
            },
            onOpenSession: { session in
                onOpenSession(session)
            }
        )
    }

    private var selectedProject: AgentProject? {
        guard let selectedWorkspaceID else {
            return nil
        }
        return sessionStore.sidebarProjects.first { $0.id == selectedWorkspaceID }
    }

    private var emptyWorkspaceTitle: String {
        if case .failed = catalogState { return L10n.text("ui.unable_to_load_workspace") }
        return L10n.text("ui.no_workspace_yet")
    }

    private var emptyWorkspaceSymbol: String {
        if case .failed = catalogState { return "exclamationmark.triangle" }
        return "folder.badge.plus"
    }

    private var emptyWorkspaceMessage: String {
        if case .failed(let message) = catalogState { return message }
        return L10n.text("ui.once_the_directory_is_open_you_can_browse")
    }

    private func synchronizeSelection() {
        let projects = sessionStore.sidebarProjects
        guard !projects.isEmpty else {
            selectedWorkspaceID = nil
            return
        }
        if let selectedWorkspaceID,
           projects.contains(where: { $0.id == selectedWorkspaceID }) {
            return
        }
        selectedWorkspaceID = sessionStore.selectedProjectID.flatMap { selectedID in
            projects.contains(where: { $0.id == selectedID }) ? selectedID : nil
        } ?? projects.first?.id
    }

    private func removeWorkspace(_ project: AgentProject) {
        pendingWorkspaceRemoval = nil
        guard selectedWorkspaceID != project.id else { return }
        sessionLoadStates.removeValue(forKey: project.id)
        sessionStore.forgetWorkspace(project)
    }

    private func refreshCatalog() async {
        catalogState = .loading
        do {
            try await sessionStore.refreshWorkspaceCatalog()
            guard !Task.isCancelled else {
                return
            }
            catalogState = .loaded
        } catch is CancellationError {
            return
        } catch {
            catalogState = .failed(error.localizedDescription)
        }
    }

    private func refreshWorkspaceContent(projectID: String) async {
        await refreshCatalog()
        guard !Task.isCancelled,
              selectedWorkspaceID == projectID,
              sessionStore.sidebarProjects.contains(where: { $0.id == projectID })
        else {
            return
        }
        await refreshWorkspaceSessions(projectID: projectID)
    }

    private func refreshWorkspaceSessions(projectID: String) async {
        guard sessionLoadStates[projectID] != .loading else { return }
        sessionLoadStates[projectID] = .loading
        do {
            try await sessionStore.refreshWorkspaceSessions(projectID: projectID)
            guard !Task.isCancelled else {
                sessionLoadStates[projectID] = fallbackSessionLoadState(for: projectID)
                return
            }
            sessionLoadStates[projectID] = .loaded
        } catch is CancellationError {
            sessionLoadStates[projectID] = fallbackSessionLoadState(for: projectID)
        } catch {
            sessionLoadStates[projectID] = .failed(error.localizedDescription)
        }
    }

    private func sessionLoadState(for projectID: String) -> WorkspaceSessionLoadState {
        sessionLoadStates[projectID] ?? fallbackSessionLoadState(for: projectID)
    }

    private func fallbackSessionLoadState(for projectID: String) -> WorkspaceSessionLoadState {
        sessionStore.sessions(forProjectID: projectID).isEmpty ? .idle : .loaded
    }

    private enum CatalogState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }
}

private enum WorkspaceSessionLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isLoading: Bool {
        self == .loading
    }
}

private enum WorkspaceActionEmphasis: Equatable {
    case primary
    case accented
}

private struct WorkspaceActionPressButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // 按下反馈直接跟随触点；减少动态效果时仅改变透明度，避免不必要的缩放运动。
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.985)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.08)
                    : .spring(response: 0.22, dampingFraction: 1),
                value: configuration.isPressed
            )
    }
}

private struct WorkspaceLibraryCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    let project: AgentProject
    let sessionCount: Int
    let worktreeCount: Int
    let isUnavailable: Bool
    let isSelected: Bool
    let tokens: ThemeTokens
    let action: () -> Void
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                cardContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                L10n.format(
                    "ui.workspace_summary",
                    project.name,
                    L10n.plural("ui.sessions_count", count: sessionCount),
                    L10n.plural("ui.worktrees_count", count: worktreeCount),
                    isUnavailable ? L10n.text("ui.need_to_retry") : L10n.text("ui.accessible"),
                    isSelected ? L10n.text("ui.selected_b4f8bea5") : ""
                )
            )

            if !isSelected {
                Menu {
                    Button(role: .destructive, action: onRemove) {
                        Label(L10n.text("ui.remove_directory"), systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.tertiaryText)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .accessibilityLabel(L10n.text("ui.remove_directory"))
                .padding(.top, 10)
                .padding(.trailing, 8)
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isUnavailable ? "folder.badge.questionmark" : "folder.fill")
                    .font(themeStore.uiFont(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isUnavailable ? tokens.warning : tokens.primaryAction)
                    .frame(width: 44, height: 44)
                    .background((isUnavailable ? tokens.warning : tokens.primaryAction).opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(project.name)
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(1)
                    Text(project.path)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 8) {
                    Group {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                        } else {
                            // 右上角的菜单覆盖在同一位置；这里保留布局空间，避免状态文案左右跳动。
                            Color.clear
                        }
                    }
                    .frame(width: 32, height: 20)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryAction)

                    Label(
                        isUnavailable ? L10n.text("ui.need_to_retry_915015f1") : L10n.text("ui.accessible"),
                        systemImage: isUnavailable ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .font(themeStore.uiFont(.caption2, weight: .semibold))
                    .foregroundStyle(isUnavailable ? tokens.warning : tokens.success)
                    .fixedSize()
                }
            }

            HStack(spacing: 8) {
                metric("\(sessionCount)", title: L10n.text("ui.session"), systemImage: "bubble.left.and.bubble.right")
                metric("\(worktreeCount)", title: "Worktree", systemImage: "arrow.triangle.branch")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(isSelected ? tokens.selectionFill : tokens.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isSelected ? tokens.primaryAction : tokens.border.opacity(0.72),
                    lineWidth: isSelected ? 2 : 1
                )
        }
    }

    private func metric(_ value: String, title: String, systemImage: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 15, weight: .semibold))
                .foregroundStyle(tokens.primaryAction)
                .frame(width: 28, height: 28)
                .background(tokens.primaryAction.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(title)
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(tokens.elevatedSurface.opacity(0.56), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct WorkspaceDetailView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var actionButtonHeight: CGFloat = 68
    @State private var isLoadingMoreSessions = false

    let recentSessions: [AgentSession]
    let sessionLoadState: WorkspaceSessionLoadState
    let canLoadMoreSessions: Bool
    let claudeChannelAvailable: Bool
    let onRefreshSessions: () -> Void
    let onLoadMoreSessions: () async -> Void
    let onStartSession: (WorkspaceSessionRuntimeChoice) -> Void
    let onOpenSession: (AgentSession) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 项目名称、路径和状态已在上方选中卡片中展示，这里直接进入操作区，
                // 避免同一屏重复一整套工作区摘要。
                workspaceActions(tokens: tokens)
                recentSessionsSection(tokens: tokens)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(tokens.background.ignoresSafeArea())
    }

    private func workspaceActions(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("ui.quick_operation"))
                .font(themeStore.uiFont(.subheadline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)

            // 创建会话是工作区页的主任务；只保留能直接开始工作的入口。
            LazyVGrid(columns: actionColumns, spacing: 12) {
                ForEach(WorkspaceSessionRuntimeChoice.allCases) { choice in
                    actionButton(
                        choice: choice,
                        subtitle: choice == .codex ? L10n.text("ui.start_using_the_default_runtime") : L10n.text("ui.get_started_with_the_claude_code_runtime"),
                        emphasis: choice == .codex ? .primary : .accented,
                        tokens: tokens
                    ) {
                        // thread 创建时就绑定 runtime；这里必须把用户选择一路传到 SessionStore。
                        onStartSession(choice)
                    }
                    // 未确认或未配置 Claude 通道时保留按钮位置但禁止误创建；能力返回后原位启用，
                    // 页面不会再从单按钮突然跳成双按钮。
                    .disabled(choice == .claude && !claudeChannelAvailable)
                }
            }
        }
    }

    private var actionColumns: [GridItem] {
        if horizontalSizeClass == .compact {
            return [GridItem(.flexible(minimum: 0), spacing: 12)]
        }
        return [
            GridItem(.flexible(minimum: 0), spacing: 12),
            GridItem(.flexible(minimum: 0), spacing: 12)
        ]
    }

    private func actionButton(
        choice: WorkspaceSessionRuntimeChoice,
        subtitle: String? = nil,
        emphasis: WorkspaceActionEmphasis,
        tokens: ThemeTokens,
        action: @escaping () -> Void
    ) -> some View {
        let foreground = actionForeground(emphasis: emphasis, tokens: tokens)
        let background = actionBackground(emphasis: emphasis, tokens: tokens)
        let border = actionBorder(emphasis: emphasis, tokens: tokens)
        let cornerRadius: CGFloat = 15

        return Button(action: action) {
            HStack(spacing: 12) {
                actionIcon(choice: choice)

                VStack(alignment: .leading, spacing: 3) {
                    Text(choice.title)
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .foregroundStyle(foreground)
                        .lineLimit(1)

                    if let subtitle {
                        Text(subtitle)
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(actionSecondaryForeground(emphasis: emphasis, tokens: tokens))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            // 所有快捷入口共用同一个随 Dynamic Type 缩放的高度，视觉和触控面积保持一致。
            .frame(maxWidth: .infinity, minHeight: actionButtonHeight, maxHeight: actionButtonHeight, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(border, lineWidth: emphasis == .accented ? 1.2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(WorkspaceActionPressButtonStyle(reduceMotion: reduceMotion))
    }

    @ViewBuilder
    private func actionIcon(choice: WorkspaceSessionRuntimeChoice) -> some View {
        // 使用中性的系统符号，避免把第三方产品图标误当成 App 自有品牌或官方背书。
        Image(systemName: choice.systemImageName)
            .font(themeStore.uiFont(size: 18, weight: .semibold))
            .foregroundStyle(
                choice == .codex
                    ? Color(red: 0.20, green: 0.24, blue: 0.29)
                    : Color(red: 0.68, green: 0.31, blue: 0.18)
            )
            .frame(width: 38, height: 38)
            .background(
                choice == .codex
                    ? Color.white
                    : Color(red: 0.973, green: 0.949, blue: 0.914),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private func actionForeground(emphasis: WorkspaceActionEmphasis, tokens: ThemeTokens) -> Color {
        emphasis == .primary ? tokens.primaryActionForeground : tokens.primaryText
    }

    private func actionSecondaryForeground(emphasis: WorkspaceActionEmphasis, tokens: ThemeTokens) -> Color {
        emphasis == .primary ? tokens.primaryActionForeground.opacity(0.78) : tokens.secondaryText
    }

    private func actionBackground(emphasis: WorkspaceActionEmphasis, tokens: ThemeTokens) -> Color {
        switch emphasis {
        case .primary:
            return tokens.primaryAction
        case .accented:
            return tokens.surface
        }
    }

    private func actionBorder(emphasis: WorkspaceActionEmphasis, tokens: ThemeTokens) -> Color {
        switch emphasis {
        case .primary:
            return tokens.primaryAction.opacity(0.92)
        case .accented:
            return tokens.primaryAction.opacity(0.24)
        }
    }

    private func recentSessionsSection(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("ui.recent_conversations"))
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Spacer()
                Button(action: onRefreshSessions) {
                    HStack(spacing: 5) {
                        if sessionLoadState.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(sessionLoadState.isLoading ? L10n.text("ui.loading") : L10n.text("ui.refresh"))
                    }
                    .font(themeStore.uiFont(.caption, weight: .medium))
                    .foregroundStyle(tokens.primaryAction)
                }
                .buttonStyle(.plain)
                .disabled(sessionLoadState.isLoading)
                .accessibilityLabel(sessionLoadState.isLoading ? L10n.text("ui.loading_recent_conversations") : L10n.text("ui.refresh_recent_conversations"))
            }

            if recentSessions.isEmpty, sessionLoadState.isLoading {
                recentSessionPlaceholders(tokens: tokens)
            } else if recentSessions.isEmpty, case .failed(let message) = sessionLoadState {
                ContentUnavailableView {
                    Label(L10n.text("ui.unable_to_load_session"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button(L10n.text("ui.reload"), action: onRefreshSessions)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(tokens.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if recentSessions.isEmpty {
                ContentUnavailableView(L10n.text("ui.no_sessions_yet"), systemImage: "bubble.left.and.bubble.right", description: Text(L10n.text("ui.after_a_new_session_is_created_in_this")))
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(tokens.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recentSessions.enumerated()), id: \.element.id) { index, session in
                        Button {
                            onOpenSession(session)
                        } label: {
                            recentSessionRow(session, tokens: tokens)
                        }
                        .buttonStyle(.plain)

                        if index < recentSessions.count - 1 {
                            Divider()
                                .overlay(tokens.border.opacity(0.62))
                                .padding(.leading, 48)
                        }
                    }

                    if canLoadMoreSessions || isLoadingMoreSessions {
                        Divider()
                            .overlay(tokens.border.opacity(0.62))

                        Button {
                            guard !isLoadingMoreSessions else { return }
                            isLoadingMoreSessions = true
                            Task {
                                await onLoadMoreSessions()
                                isLoadingMoreSessions = false
                            }
                        } label: {
                            HStack(spacing: 7) {
                                if isLoadingMoreSessions {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "chevron.down")
                                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                                }
                                Text(isLoadingMoreSessions ? L10n.text("ui.loading") : L10n.text("ui.show_more"))
                            }
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                            .foregroundStyle(tokens.primaryAction)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoadingMoreSessions)
                    }
                }
                .background(tokens.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tokens.border.opacity(0.72), lineWidth: 1)
                }
            }
        }
    }

    private func recentSessionPlaceholders(tokens: ThemeTokens) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tokens.elevatedSurface)
                        .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(tokens.elevatedSurface)
                            .frame(width: 180, height: 12)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(tokens.elevatedSurface)
                            .frame(width: 108, height: 9)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 62)

                if index < 2 {
                    Divider()
                        .overlay(tokens.border.opacity(0.62))
                        .padding(.leading, 48)
                }
            }
        }
        .background(tokens.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tokens.border.opacity(0.72), lineWidth: 1)
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("ui.loading_recent_conversations"))
    }

    private func recentSessionRow(_ session: AgentSession, tokens: ThemeTokens) -> some View {
        let status = session.displayStatus(foregroundActivity: nil)
        let statusTone = tokens.tint(for: status.tone)

        return HStack(spacing: 12) {
            Image(systemName: session.isRunning ? "waveform.circle.fill" : "bubble.left.fill")
                .font(themeStore.uiFont(size: 17, weight: .semibold))
                .foregroundStyle(statusTone)
                .frame(width: 34, height: 34)
                .background(statusTone.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(themeStore.uiFont(.callout, weight: .medium))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(runtimeTitle(for: session))
                    Text("·")
                    Text(status.title)
                }
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(statusTone)
            }

            Spacer(minLength: 8)

            Text(sessionTimeText(for: session))
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.tertiaryText)
                .fixedSize()

            Image(systemName: "chevron.right")
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(tokens.tertiaryText)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 62)
        .contentShape(Rectangle())
    }

    private func runtimeTitle(for session: AgentSession) -> String {
        let provider = session.runtimeProvider ?? session.source
        return provider.lowercased().contains("claude")
            ? L10n.text("ui.runtime_optional")
            : L10n.text("ui.runtime_default")
    }

    private func sessionTimeText(for session: AgentSession) -> String {
        guard let date = session.recencyAt ?? session.updatedAt ?? session.createdAt else { return "" }
        if Calendar.current.isDateInToday(date) {
            return Self.sessionTimeFormatter.string(from: date)
        }
        return Self.sessionDateFormatter.string(from: date)
    }

    private static let sessionTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("Hm")
        return formatter
    }()

    private static let sessionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter
    }()
}
