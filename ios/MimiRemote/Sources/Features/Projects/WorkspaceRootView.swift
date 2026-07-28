import SwiftUI

/// MeeGo / Harmattan 图标底板不是规则圆角矩形，也不是完全对称的超椭圆。
/// 归一化 Bézier 控制点让上下边略平、左右边轻微收腰，并保留四角细微不同的饱满度。
private struct WorkspaceIconMeeGoShape: Shape {
    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * x,
                y: rect.minY + rect.height * y
            )
        }

        var path = Path()
        path.move(to: point(0.27, 0.045))
        path.addCurve(
            to: point(0.75, 0.035),
            control1: point(0.41, 0.018),
            control2: point(0.61, 0.015)
        )
        path.addCurve(
            to: point(0.955, 0.26),
            control1: point(0.88, 0.045),
            control2: point(0.945, 0.14)
        )
        path.addCurve(
            to: point(0.95, 0.72),
            control1: point(0.985, 0.40),
            control2: point(0.98, 0.59)
        )
        path.addCurve(
            to: point(0.71, 0.955),
            control1: point(0.93, 0.85),
            control2: point(0.84, 0.945)
        )
        path.addCurve(
            to: point(0.26, 0.96),
            control1: point(0.57, 0.985),
            control2: point(0.40, 0.985)
        )
        path.addCurve(
            to: point(0.045, 0.70),
            control1: point(0.14, 0.945),
            control2: point(0.055, 0.84)
        )
        path.addCurve(
            to: point(0.055, 0.25),
            control1: point(0.018, 0.57),
            control2: point(0.025, 0.39)
        )
        path.addCurve(
            to: point(0.27, 0.045),
            control1: point(0.065, 0.13),
            control2: point(0.15, 0.055)
        )
        path.closeSubpath()
        return path
    }
}

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

    var brandAssetName: String {
        switch self {
        case .codex:
            return "ChatGPT"
        case .claude:
            return "Claude"
        }
    }

    static func available(claudeChannelAvailable: Bool) -> [Self] {
        claudeChannelAvailable ? [.codex, .claude] : [.codex]
    }
}

enum WorkspaceStripLayout {
    static let horizontalPadding: CGFloat = 24
    // 316pt 能容纳 Emoji、路径和一行实时状态，同时在 iPad mini 上露出相邻卡片提示横向滚动。
    static let cardWidth: CGFloat = 316
    static let stripHeight: CGFloat = 166

    static func minimumContentWidth(viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - horizontalPadding * 2)
    }
}

enum WorkspaceSessionAgeBoundary {
    static let staleInterval: TimeInterval = 12 * 60 * 60

    static func firstStaleIndex(in sessions: [AgentSession], now: Date = Date()) -> Int? {
        // 工作区会话已经按 SessionIndexStore.orderingDate 倒序排列；
        // 这里复用同一时间口径，避免列表顺序与 12 小时分组依据不一致。
        sessions.firstIndex { session in
            now.timeIntervalSince(SessionIndexStore.orderingDate(for: session)) > staleInterval
        }
    }
}

/// 工作区只维护本地浏览选择。只有用户明确进入会话或新建会话时，才交给 SessionStore 改变活动上下文。
struct WorkspaceRootView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var appearanceStore: WorkspaceAppearanceStore

    let onStartSession: (AgentProject, WorkspaceSessionRuntimeChoice) -> Void
    let onOpenSession: (AgentSession) -> Void
    let embedsNavigationStack: Bool
    private let currentDate: () -> Date

    @State private var selectedWorkspaceID: String?
    @State private var catalogState: CatalogState = .idle
    @State private var sessionLoadStates: [String: WorkspaceSessionLoadState] = [:]
    @State private var isPresentingOpenWorkspace = false
    @State private var pendingWorkspaceRemoval: AgentProject?

    init(
        onStartSession: @escaping (AgentProject, WorkspaceSessionRuntimeChoice) -> Void,
        onOpenSession: @escaping (AgentSession) -> Void = { _ in },
        embedsNavigationStack: Bool = true,
        appearanceStore: WorkspaceAppearanceStore? = nil,
        initialWorkspaceID: String? = nil,
        currentDate: @escaping () -> Date = Date.init
    ) {
        self.onStartSession = onStartSession
        self.onOpenSession = onOpenSession
        self.embedsNavigationStack = embedsNavigationStack
        self.currentDate = currentDate
        _appearanceStore = StateObject(wrappedValue: appearanceStore ?? WorkspaceAppearanceStore())
        // 正常入口仍由 synchronizeSelection 恢复选择；显式初值只服务于确定性的预览和视觉快照。
        _selectedWorkspaceID = State(initialValue: initialWorkspaceID)
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
        .task(id: appStore.activeHostScope) {
            migrateLegacyWorkspaceAppearance()
            synchronizeSelection()
            // 每次进入工作区都做轻量目录同步，同时执行旧版自动候选数据清理；
            // 该请求不改变当前会话和 WebSocket，上层选择保持稳定。
            await refreshCatalog()
            synchronizeSelection()
        }
        .onChange(of: appStore.connectionProfiles) { _, _ in
            // 这里只重试本地偏好迁移，不重新请求目录。删除或修改重复 endpoint 后，
            // 当前 Profile 一旦成为唯一匹配，就应立即恢复旧版自定义 emoji。
            migrateLegacyWorkspaceAppearance()
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

    private func migrateLegacyWorkspaceAppearance() {
        appearanceStore.migrateLegacyValueIfNeeded(
            profileID: appStore.activeHostScope.profileID,
            endpoint: appStore.endpoint,
            profiles: appStore.connectionProfiles
        )
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
                                    profileID: appStore.activeHostScope.profileID,
                                    appearanceStore: appearanceStore,
                                    gitSummary: nil,
                                    isGitSummaryLoading: true,
                                    hasRunningSession: false,
                                    lastActivityAt: nil,
                                    currentDate: currentDate,
                                    isUnavailable: false,
                                    isSelected: false,
                                    allowsCustomization: false,
                                    tokens: tokens,
                                    action: {},
                                    onRemove: {}
                                )
                                .frame(width: WorkspaceStripLayout.cardWidth)
                                .redacted(reason: .placeholder)
                            }
                        } else {
                            ForEach(sessionStore.sidebarProjects) { project in
                                let projectSessions = sessionStore.sessions(forProjectID: project.id)
                                WorkspaceLibraryCard(
                                    project: project,
                                    profileID: appStore.activeHostScope.profileID,
                                    appearanceStore: appearanceStore,
                                    gitSummary: sessionStore.workspaceGitSummaryByPath[project.path],
                                    isGitSummaryLoading: sessionStore.refreshingWorkspaceGitSummaryPaths.contains(project.path),
                                    hasRunningSession: projectSessions.contains(where: \.isRunning),
                                    lastActivityAt: workspaceActivityDate(projectID: project.id, sessions: projectSessions),
                                    currentDate: currentDate,
                                    isUnavailable: sessionStore.isWorkspaceUnavailable(project.id),
                                    isSelected: selectedWorkspaceID == project.id,
                                    allowsCustomization: true,
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
            currentDate: currentDate,
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

    private func workspaceActivityDate(projectID: String, sessions: [AgentSession]) -> Date? {
        let sessionDate = sessions
            .map { SessionIndexStore.orderingDate(for: $0) }
            .filter { $0 != .distantPast }
            .max()
        return sessionDate
            ?? sessionStore.recentWorkspaces.first(where: { $0.id == projectID })?.lastOpenedAt
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

    private func refreshCatalog(forceGitSummary: Bool = false) async {
        catalogState = .loading
        do {
            try await sessionStore.refreshWorkspaceCatalog()
            guard !Task.isCancelled else {
                return
            }
            catalogState = .loaded
            await sessionStore.refreshWorkspaceGitSummaries(
                for: sessionStore.sidebarProjects,
                force: forceGitSummary
            )
        } catch is CancellationError {
            return
        } catch {
            catalogState = .failed(error.localizedDescription)
        }
    }

    private func refreshWorkspaceContent(projectID: String) async {
        await refreshCatalog(forceGitSummary: true)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let project: AgentProject
    let profileID: String
    @ObservedObject var appearanceStore: WorkspaceAppearanceStore
    let gitSummary: GitStatusResponse?
    let isGitSummaryLoading: Bool
    let hasRunningSession: Bool
    let lastActivityAt: Date?
    let currentDate: () -> Date
    let isUnavailable: Bool
    let isSelected: Bool
    let allowsCustomization: Bool
    let tokens: ThemeTokens
    let action: () -> Void
    let onRemove: () -> Void
    @State private var isPresentingEmojiPicker = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                cardContent
            }
            .buttonStyle(WorkspaceActionPressButtonStyle(reduceMotion: reduceMotion))
            .accessibilityLabel(accessibilitySummary)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.accent)
                    .frame(width: 32, height: 32)
                    .padding(.top, 10)
                    .padding(.trailing, 8)
                    .accessibilityHidden(true)
            } else {
                Menu {
                    Button {
                        isPresentingEmojiPicker = true
                    } label: {
                        Label(L10n.text("ui.workspace_icon"), systemImage: "face.smiling")
                    }
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

            if allowsCustomization {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Button {
                            isPresentingEmojiPicker = true
                        } label: {
                            Color.clear
                                .frame(width: 52, height: 52)
                                .contentShape(WorkspaceIconMeeGoShape())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            L10n.format(
                                "ui.change_workspace_icon_value",
                                project.name,
                                displayedEmoji
                            )
                        )
                        .popover(isPresented: $isPresentingEmojiPicker, arrowEdge: .top) {
                            WorkspaceEmojiPicker(
                                project: project,
                                profileID: profileID,
                                appearanceStore: appearanceStore,
                                tokens: tokens
                            )
                        }
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 14)
                .padding(.leading, 14)
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                emojiTile

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
                Color.clear.frame(width: 28, height: 1)
            }

            Divider()
                .overlay(
                    isSelected
                        ? tokens.primaryText.opacity(0.14)
                        : tokens.border.opacity(0.56)
                )

            TimelineView(.periodic(from: .now, by: 60)) { _ in
                // TimelineView 只负责按分钟触发刷新；时间来源可在视觉测试中固定，
                // 生产环境默认仍由 Date.init 返回当前时刻。
                metadataRow(now: currentDate())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .background(
            isSelected ? tokens.workspaceCardSelectionFill : tokens.contentPanelBackground,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            if !isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(tokens.border.opacity(0.72), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(
            reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.28, dampingFraction: 1),
            value: isSelected
        )
    }

    private var displayedEmoji: String {
        appearanceStore.emoji(profileID: profileID, projectID: project.id)
    }

    private var emojiTile: some View {
        let palette: [Color] = [
            Color(red: 0.91, green: 0.63, blue: 0.48),
            Color(red: 0.47, green: 0.67, blue: 0.78),
            Color(red: 0.76, green: 0.64, blue: 0.42),
            Color(red: 0.88, green: 0.72, blue: 0.34),
            Color(red: 0.64, green: 0.70, blue: 0.48),
            Color(red: 0.72, green: 0.53, blue: 0.72)
        ]
        let tint = palette[WorkspaceAppearanceStore.tintIndex(for: displayedEmoji, count: palette.count)]

        return Text(displayedEmoji)
            .font(.system(size: 30))
            .frame(width: 52, height: 52)
            .background(
                tint.opacity(colorScheme == .dark ? 0.30 : 0.18),
                in: WorkspaceIconMeeGoShape()
            )
            .overlay(alignment: .bottomTrailing) {
                if hasRunningSession {
                    Circle()
                        .fill(tokens.primaryAction)
                        .frame(width: 11, height: 11)
                        .overlay {
                            Circle()
                                .stroke(
                                    isSelected
                                        ? tokens.workspaceCardSelectionFill
                                        : tokens.contentPanelBackground,
                                    lineWidth: 2
                                )
                        }
                        .offset(x: 1, y: 1)
                        .accessibilityHidden(true)
                }
            }
            .opacity(isUnavailable ? 0.62 : 1)
            .accessibilityHidden(true)
    }

    private func metadataRow(now: Date) -> some View {
        HStack(spacing: 10) {
            if let branch = gitBranch {
                Label(branch, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 28)
                    .background(tokens.elevatedSurface.opacity(0.62), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else if isGitSummaryLoading {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tokens.elevatedSurface.opacity(0.56))
                    .frame(width: 58, height: 28)
            }

            if let status = cardStatus {
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.color(tokens: tokens))
                        .frame(width: 7, height: 7)
                    Text(status.text)
                        .lineLimit(1)
                }
                .font(themeStore.uiFont(.caption2, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
                .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 4)

            if let activity = activityText(now: now) {
                Text(activity)
                    .font(themeStore.uiFont(.caption2))
                    .foregroundStyle(tokens.tertiaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
    }

    private var gitBranch: String? {
        let branch = gitSummary?.branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let branch, !branch.isEmpty {
            return branch
        }
        let head = gitSummary?.head?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let head, !head.isEmpty {
            return head
        }
        return nil
    }

    private var cardStatus: WorkspaceCardStatus? {
        if isUnavailable {
            return WorkspaceCardStatus(text: L10n.text("ui.need_to_retry"), tone: .danger)
        }
        guard let gitSummary else {
            return hasRunningSession
                ? WorkspaceCardStatus(text: L10n.text("ui.running"), tone: .accent)
                : nil
        }
        guard gitSummary.isRepository else {
            return WorkspaceCardStatus(text: L10n.text("ui.not_a_git_repository"), tone: .secondary)
        }
        if !gitSummary.files.isEmpty {
            return WorkspaceCardStatus(
                text: L10n.format("ui.git_changes_count_value", gitSummary.files.count),
                tone: .warning
            )
        }

        let ahead = gitSummary.ahead ?? 0
        let behind = gitSummary.behind ?? 0
        if ahead > 0, behind > 0 {
            return WorkspaceCardStatus(text: L10n.text("ui.git_branch_diverged"), tone: .warning)
        }
        if behind > 0 {
            return WorkspaceCardStatus(text: L10n.format("ui.behind_value", behind), tone: .warning)
        }
        if ahead > 0 {
            return WorkspaceCardStatus(text: L10n.format("ui.leading_value", ahead), tone: .accent)
        }
        if gitSummary.upstream?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return WorkspaceCardStatus(text: L10n.text("ui.git_synced"), tone: .success)
        }
        return WorkspaceCardStatus(text: L10n.text("ui.clean_work_area"), tone: .success)
    }

    private func activityText(now: Date) -> String? {
        guard let lastActivityAt else { return nil }
        let interval = max(0, now.timeIntervalSince(lastActivityAt))
        if interval < 5 * 60 {
            return L10n.text("ui.active_just_now")
        }
        if interval < 60 * 60 {
            return L10n.format("ui.minutes_ago_value", Int(interval / 60))
        }
        if interval < 24 * 60 * 60 {
            return L10n.format("ui.hours_ago_value", Int(interval / 3600))
        }
        return L10n.format("ui.days_ago_value", Int(interval / (24 * 3600)))
    }

    private var accessibilitySummary: String {
        let statusParts = [
            hasRunningSession ? L10n.text("ui.running") : nil,
            cardStatus?.text
        ].compactMap { $0 }
        let status = statusParts.isEmpty
            ? L10n.text("ui.git_status_unknown")
            : statusParts.joined(separator: ", ")
        let selected = isSelected ? L10n.text("ui.selected_b4f8bea5") : ""
        return L10n.format(
            "ui.workspace_card_summary",
            project.name,
            project.path,
            status,
            selected
        )
    }
}

private struct WorkspaceCardStatus {
    enum Tone {
        case accent
        case success
        case warning
        case danger
        case secondary
    }

    let text: String
    let tone: Tone

    func color(tokens: ThemeTokens) -> Color {
        switch tone {
        case .accent:
            return tokens.accent
        case .success:
            return tokens.success
        case .warning:
            return tokens.warning
        case .danger:
            return tokens.warning
        case .secondary:
            return tokens.tertiaryText
        }
    }
}

private struct WorkspaceEmojiPicker: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: AgentProject
    let profileID: String
    @ObservedObject var appearanceStore: WorkspaceAppearanceStore
    let tokens: ThemeTokens
    @State private var customInput = ""
    @State private var validationMessage: String?

    private let columns = Array(repeating: GridItem(.fixed(44), spacing: 8), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("ui.workspace_icon"))
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(project.name)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(WorkspaceAppearanceStore.builtInEmoji, id: \.self) { emoji in
                    Button {
                        appearanceStore.setCustomEmoji(emoji, profileID: profileID, projectID: project.id)
                        dismiss()
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Text(emoji)
                                .font(.system(size: 26))
                                .frame(width: 44, height: 44)
                                .background(
                                    tokens.elevatedSurface.opacity(0.68),
                                    in: WorkspaceIconMeeGoShape()
                                )
                            if currentEmoji == emoji {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(themeStore.uiFont(size: 12, weight: .semibold))
                                    .foregroundStyle(tokens.primaryAction)
                                    .background(tokens.surface, in: Circle())
                            }
                        }
                    }
                    .buttonStyle(WorkspaceActionPressButtonStyle(reduceMotion: reduceMotion))
                    .accessibilityLabel(emoji)
                    .accessibilityAddTraits(currentEmoji == emoji ? .isSelected : [])
                }
            }

            Divider()
                .overlay(tokens.border.opacity(0.6))

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("ui.custom_emoji"))
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)

                HStack(spacing: 8) {
                    TextField(L10n.text("ui.enter_one_emoji"), text: $customInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 24))
                        .submitLabel(.done)
                        .onSubmit(applyCustomEmoji)

                    Button(L10n.text("ui.apply"), action: applyCustomEmoji)
                        .buttonStyle(.borderedProminent)
                        .tint(tokens.primaryAction)
                        .disabled(customInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.warning)
                }
            }

            Button {
                appearanceStore.setCustomEmoji(nil, profileID: profileID, projectID: project.id)
                dismiss()
            } label: {
                Label(L10n.text("ui.restore_default_appearance"), systemImage: "arrow.counterclockwise")
            }
            .font(themeStore.uiFont(.callout, weight: .medium))
            .disabled(appearanceStore.customEmoji(profileID: profileID, projectID: project.id) == nil)
        }
        .padding(18)
        .frame(width: 336)
        .background(tokens.surface)
        .onAppear {
            customInput = appearanceStore.customEmoji(profileID: profileID, projectID: project.id) ?? ""
        }
    }

    private var currentEmoji: String {
        appearanceStore.emoji(profileID: profileID, projectID: project.id)
    }

    private func applyCustomEmoji() {
        guard let emoji = WorkspaceAppearanceStore.normalizedEmoji(customInput) else {
            validationMessage = L10n.text("ui.enter_one_valid_emoji")
            return
        }
        appearanceStore.setCustomEmoji(emoji, profileID: profileID, projectID: project.id)
        dismiss()
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
    let currentDate: () -> Date
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
        tokens: ThemeTokens,
        action: @escaping () -> Void
    ) -> some View {
        let cornerRadius: CGFloat = 15

        return Button(action: action) {
            HStack(spacing: 12) {
                actionIcon(choice: choice)

                Text(choice.title)
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            // 所有快捷入口共用同一个随 Dynamic Type 缩放的高度，视觉和触控面积保持一致。
            .frame(maxWidth: .infinity, minHeight: actionButtonHeight, maxHeight: actionButtonHeight, alignment: .leading)
            // 快捷入口是立即执行的动作；使用与输入面板同层的暖石墨填充，
            // 在暖黑页面上形成明确但克制的内容层级。
            .background(tokens.contentPanelBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(WorkspaceActionPressButtonStyle(reduceMotion: reduceMotion))
    }

    @ViewBuilder
    private func actionIcon(choice: WorkspaceSessionRuntimeChoice) -> some View {
        // 只恢复运行时图标；操作卡片继续使用中性背景，不恢复 Codex 入口原来的深色强调底。
        Image(choice.brandAssetName)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(
                width: choice == .codex ? 38 : 20,
                height: choice == .codex ? 38 : 20
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
                .background(tokens.contentPanelBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if recentSessions.isEmpty {
                ContentUnavailableView(L10n.text("ui.no_sessions_yet"), systemImage: "bubble.left.and.bubble.right", description: Text(L10n.text("ui.after_a_new_session_is_created_in_this")))
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(tokens.contentPanelBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    let firstStaleIndex = WorkspaceSessionAgeBoundary.firstStaleIndex(
                        in: recentSessions,
                        now: currentDate()
                    )

                    ForEach(Array(recentSessions.enumerated()), id: \.element.id) { index, session in
                        if index == firstStaleIndex {
                            twelveHourBoundary(tokens: tokens)
                        } else if index > 0 {
                            Divider()
                                .overlay(tokens.border.opacity(0.62))
                                .padding(.leading, 48)
                        }

                        Button {
                            onOpenSession(session)
                        } label: {
                            recentSessionRow(session, tokens: tokens)
                        }
                        .buttonStyle(.plain)
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
                .background(tokens.contentPanelBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tokens.border.opacity(0.72), lineWidth: 1)
                }
            }
        }
    }

    private func twelveHourBoundary(tokens: ThemeTokens) -> some View {
        ZStack {
            // 直接复用普通列表分隔线的位置，只在中间留出文案缺口，
            // 避免“默认分隔线 + 分组分隔线”叠成两道横线。
            Rectangle()
                .fill(tokens.border.opacity(0.62))
                .frame(height: 0.5)

            Text(L10n.text("ui.twelve_hours_ago"))
                .font(themeStore.uiFont(.caption2, weight: .medium))
                .foregroundStyle(tokens.tertiaryText)
                .padding(.horizontal, 8)
                .background(tokens.contentPanelBackground)
                .fixedSize()
        }
        .padding(.leading, 48)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("ui.twelve_hours_ago"))
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
        .background(tokens.contentPanelBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    SessionRuntimeBadge(session: session)
                    Text(status.title)
                        .foregroundStyle(statusTone)
                }
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.secondaryText)
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

    private func sessionTimeText(for session: AgentSession) -> String {
        guard let date = session.recencyAt ?? session.updatedAt ?? session.createdAt else { return "" }
        if Calendar.current.isDate(date, inSameDayAs: currentDate()) {
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
