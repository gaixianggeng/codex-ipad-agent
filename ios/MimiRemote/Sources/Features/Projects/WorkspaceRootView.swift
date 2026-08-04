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

    var runtimeProvider: String {
        switch self {
        case .codex:
            return "codex"
        case .claude:
            return "claude"
        }
    }

    var listTitle: String {
        switch self {
        case .codex:
            return L10n.text("ui.runtime_default")
        case .claude:
            return L10n.text("ui.runtime_claude_short")
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
    // 316pt 能容纳角色头像、路径和一行实时状态，同时在 iPad mini 上露出相邻卡片提示横向滚动。
    static let cardWidth: CGFloat = 316
    static let stripHeight: CGFloat = 166

    static func minimumContentWidth(viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - horizontalPadding * 2)
    }
}

enum WorkspaceSessionAgeBoundary {
    static let staleInterval: TimeInterval = 12 * 60 * 60

    static func firstStaleIndex(
        in sessions: [AgentSession],
        excludingSessionIDs: Set<SessionID> = [],
        now: Date = Date()
    ) -> Int? {
        // 工作区会话已经按 SessionIndexStore.orderingDate 倒序排列；
        // 置顶会话可以跨越时间分组，因此排除后再寻找普通会话的 12 小时边界。
        sessions.firstIndex { session in
            !excludingSessionIDs.contains(session.id) &&
            now.timeIntervalSince(SessionIndexStore.orderingDate(for: session)) > staleInterval
        }
    }
}

/// View 层只记录“哪次调用仍有资格回写”，真实请求复用继续由 SessionStore single-flight 决定。
struct WorkspaceSessionLoadInvocationTokens {
    private var latestByKey: [WorkspaceSessionPresentationKey: UUID] = [:]

    @discardableResult
    mutating func begin(for key: WorkspaceSessionPresentationKey) -> UUID {
        let invocationID = UUID()
        latestByKey[key] = invocationID
        return invocationID
    }

    func isCurrent(_ invocationID: UUID, for key: WorkspaceSessionPresentationKey) -> Bool {
        latestByKey[key] == invocationID
    }

    mutating func remove(where shouldRemove: (WorkspaceSessionPresentationKey) -> Bool) {
        latestByKey = latestByKey.filter { !shouldRemove($0.key) }
    }
}

enum WorkspaceCatalogLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum WorkspaceCatalogLoadResult: Equatable {
    case loaded
    case cancelled
    case failed(String)
}

enum WorkspaceSessionLoadFailureDisposition: Equatable {
    case cancelled
    case failed(String)
}

/// Session 首屏和 catalog/open 使用同一套明确取消分类，避免 URL transport 取消落入用户错误态。
func workspaceSessionLoadFailureDisposition(_ error: Error) -> WorkspaceSessionLoadFailureDisposition {
    isCancellationError(error) ? .cancelled : .failed(error.localizedDescription)
}

struct WorkspaceCatalogRefreshScope: Equatable {
    let hostScope: HostScope
    let credentialsSuspended: Bool
}

struct WorkspaceSessionRefreshScope: Equatable {
    let presentationKey: WorkspaceSessionPresentationKey?
    let needsInitialLoad: Bool
}

/// Catalog 没有底层 single-flight；这里只隔离 View 调用的提交权，避免旧请求回写或把取消留成永久 loading。
struct WorkspaceCatalogLoadCoordinator {
    private(set) var state: WorkspaceCatalogLoadState = .idle
    private var currentInvocationID: UUID?

    @discardableResult
    mutating func begin() -> UUID {
        let invocationID = UUID()
        currentInvocationID = invocationID
        state = .loading
        return invocationID
    }

    func isCurrent(_ invocationID: UUID) -> Bool {
        currentInvocationID == invocationID
    }

    @discardableResult
    mutating func complete(
        _ invocationID: UUID,
        result: WorkspaceCatalogLoadResult,
        hasCachedProjects: Bool
    ) -> Bool {
        guard isCurrent(invocationID) else {
            return false
        }
        switch result {
        case .loaded:
            state = .loaded
        case .cancelled:
            state = hasCachedProjects ? .loaded : .idle
        case .failed(let message):
            state = .failed(message)
        }
        return true
    }
}

private struct WorkspaceGitInspectionTarget: Identifiable {
    let id: String
    let name: String
    let path: String

    init(project: AgentProject) {
        id = project.id
        name = project.name
        path = project.path
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
    @State private var selectedSessionRuntime: WorkspaceSessionRuntimeChoice = .codex
    @State private var catalogLoad = WorkspaceCatalogLoadCoordinator()
    @State private var runtimeSessionPagesByKey: [WorkspaceSessionPresentationKey: WorkspaceRuntimeSessionPageState] = [:]
    @State private var sessionLoadStates: [WorkspaceSessionPresentationKey: WorkspaceSessionLoadState] = [:]
    @State private var sessionLoadInvocationTokens = WorkspaceSessionLoadInvocationTokens()
    /// canonical Store 可以持有超采样得到的额外 root；这里仅记录每个工作区已经向用户展开多少条。
    /// key 带 HostScope、路径和 Runtime，避免跨 Mac、目录身份或引擎复用旧窗口。
    @State private var workspaceSessionVisibleLimitByKey: [WorkspaceSessionPresentationKey: Int] = [:]
    @State private var isPresentingOpenWorkspace = false
    @State private var gitInspectionTarget: WorkspaceGitInspectionTarget?

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
        let catalogRefreshScope = WorkspaceCatalogRefreshScope(
            hostScope: appStore.activeHostScope,
            credentialsSuspended: appStore.isCredentialMemorySuspended
        )
        let selectedSessionPresentationKey = selectedProject.map(workspaceSessionPresentationKey(for:))
        let sessionRefreshScope = WorkspaceSessionRefreshScope(
            presentationKey: selectedSessionPresentationKey,
            needsInitialLoad: selectedSessionPresentationKey.map {
                runtimeSessionPagesByKey[$0]?.hasLoadedFirstPage != true
            } ?? false
        )

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
        .task(id: catalogRefreshScope) {
            // 后台会主动清空内存凭据；恢复完成发布 false 后，完整 scope 会确定性触发一次新刷新。
            guard !catalogRefreshScope.credentialsSuspended else {
                return
            }
            migrateLegacyWorkspaceAppearance()
            synchronizeSelection()
            // 每次进入工作区都做轻量目录同步，同时执行旧版自动候选数据清理；
            // 该请求不改变当前会话和 WebSocket，上层选择保持稳定。
            await refreshCatalog()
            synchronizeSelection()
        }
        .onChange(of: appStore.connectionProfiles) { _, _ in
            // 这里只重试本地偏好迁移，不重新请求目录。删除或修改重复 endpoint 后，
            // 当前 Profile 一旦成为唯一匹配，就应立即恢复旧版自定义图标值。
            migrateLegacyWorkspaceAppearance()
        }
        .task {
            // 两个新建入口先稳定渲染；Claude 通道能力独立在后台刷新，不能让网络往返
            // 决定按钮何时才出现在布局里。
            await sessionStore.refreshAppServerModelOptions()
        }
        .task(id: sessionRefreshScope) {
            guard sessionRefreshScope.needsInitialLoad,
                  let presentationKey = sessionRefreshScope.presentationKey,
                  let project = sessionStore.sidebarProjects.first(where: {
                      $0.id == presentationKey.workspaceID && $0.path == presentationKey.workspacePath
                  })
            else { return }
            await refreshWorkspaceSessions(project: project, presentationKey: presentationKey)
        }
        .onChange(of: sessionStore.sidebarProjects.map(\.id)) { _, _ in
            synchronizeSelection()
        }
        .onChange(of: sessionStore.hasClaudeRuntimeChannel) { _, isAvailable in
            if !isAvailable, selectedSessionRuntime == .claude {
                selectedSessionRuntime = .codex
            }
        }
        .sheet(isPresented: $isPresentingOpenWorkspace) {
            OpenWorkspaceSheet { workspaceID in
                // 工作区页使用本地浏览选择；Sheet 成功打开目录后要显式切到新工作区，
                // 不能依赖全局 selectedProjectID，否则会破坏浏览选择与会话上下文的解耦。
                selectedWorkspaceID = workspaceID
            }
        }
        .sheet(item: $gitInspectionTarget) { target in
            NavigationStack {
                DiffPanelView(workspacePath: target.path)
                    .navigationTitle(target.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.text("ui.complete")) {
                                gitInspectionTarget = nil
                            }
                        }
                    }
            }
            .presentationDetents([.large])
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
            .accessibilityIdentifier("workspace.browser")
            .navigationTitle(L10n.text("ui.workspace"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresentingOpenWorkspace = true
                    } label: {
                        WorkbenchChromeIcon(systemName: "folder.badge.plus")
                    }
                    // 顶栏的栏目选中态已经承担品牌识别；全局目录操作使用系统中性材质，
                    // 避免与选中工作区的梅紫填充形成两个大面积焦点。
                    .foregroundStyle(tokens.primaryText)
                    .accessibilityLabel(L10n.text("ui.open_directory"))
                    .accessibilityIdentifier("workspace.toolbar.openDirectory")
                }
            }
    }

    @ViewBuilder
    private func workspaceBrowser(tokens: ThemeTokens) -> some View {
        if sessionStore.sidebarProjects.isEmpty {
            if catalogLoad.state == .loading {
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
        if case .failed = catalogLoad.state {
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
        let profileID = appStore.activeHostScope.profileID
        let projectIDs = sessionStore.sidebarProjects.map(\.id)
        let iconStyle = appearanceStore.style(profileID: profileID)
        let characterAssignments = appearanceStore.characterAssignments(
            style: iconStyle,
            profileID: profileID,
            projectIDs: projectIDs
        )
        let emojiAssignments = appearanceStore.emojiAssignments(
            profileID: profileID,
            projectIDs: projectIDs
        )

        return ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        if catalogLoad.state == .loading && sessionStore.sidebarProjects.isEmpty {
                            ForEach(0..<4, id: \.self) { index in
                                WorkspaceLibraryCard(
                                    project: AgentProject(id: "loading-\(index)", name: L10n.text("ui.loading_workspace"), path: "/Users/you/code/project"),
                                    profileID: profileID,
                                    appearanceStore: appearanceStore,
                                    iconStyle: iconStyle,
                                    displayedCharacter: appearanceStore.character(
                                        style: iconStyle,
                                        profileID: profileID,
                                        projectID: "loading-\(index)"
                                    ),
                                    displayedEmoji: appearanceStore.emoji(
                                        profileID: profileID,
                                        projectID: "loading-\(index)"
                                    ),
                                    unavailableCharacterIDs: [],
                                    unavailableEmoji: [],
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
                                    onOpenGitChanges: {},
                                    onConfirmRemove: {}
                                )
                                .frame(width: WorkspaceStripLayout.cardWidth)
                                .redacted(reason: .placeholder)
                            }
                        } else {
                            ForEach(sessionStore.sidebarProjects) { project in
                                let projectSessions = sessionStore.sessions(forProjectID: project.id)
                                let displayedCharacter = characterAssignments[project.id]
                                    ?? appearanceStore.character(
                                        style: iconStyle,
                                        profileID: profileID,
                                        projectID: project.id
                                    )
                                let displayedEmoji = emojiAssignments[project.id]
                                    ?? appearanceStore.emoji(profileID: profileID, projectID: project.id)
                                let unavailableCharacterIDs: Set<String> =
                                    projectIDs.count
                                        <= WorkspaceAppearanceStore.characters(for: iconStyle).count
                                    ? Set(
                                        characterAssignments.compactMap { otherProjectID, character in
                                            otherProjectID == project.id ? nil : character.id
                                        }
                                    )
                                    : []
                                let unavailableEmoji: Set<String> =
                                    projectIDs.count <= WorkspaceAppearanceStore.builtInEmoji.count
                                    ? Set(
                                        emojiAssignments.compactMap { otherProjectID, emoji in
                                            otherProjectID == project.id ? nil : emoji
                                        }
                                    )
                                    : []
                                WorkspaceLibraryCard(
                                    project: project,
                                    profileID: profileID,
                                    appearanceStore: appearanceStore,
                                    iconStyle: iconStyle,
                                    displayedCharacter: displayedCharacter,
                                    displayedEmoji: displayedEmoji,
                                    unavailableCharacterIDs: unavailableCharacterIDs,
                                    unavailableEmoji: unavailableEmoji,
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
                                } onOpenGitChanges: {
                                    gitInspectionTarget = WorkspaceGitInspectionTarget(project: project)
                                } onConfirmRemove: {
                                    removeWorkspace(project)
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
        let presentationKey = workspaceSessionPresentationKey(for: project)
        let cachedPageState = runtimeSessionPagesByKey[presentationKey]
        // Store 已有首屏时先按当前 Runtime 投影，避免进入工作区或切换筛选后先退回骨架屏；
        // authoritative 请求仍会在后台刷新，并在返回后接管独立 cursor 与 hasMore。
        let storedRuntimeSessions = sessionStore.sessions(forProjectID: project.id).filter { session in
            sessionStore.isListableSession(session)
                && CodexAppServerSessionRuntime.normalizedRuntimeProvider(session.runtimeProvider ?? session.source)
                    == presentationKey.runtimeProvider
        }
        let loadedSessions = cachedPageState?.sessions ?? storedRuntimeSessions
        let loadState = sessionLoadState(for: presentationKey)
        let visibleLimit = workspaceSessionVisibleLimit(for: presentationKey)
        return WorkspaceDetailView(
            // Store 保留全部已取回 root 作为预取缓冲；工作区详情按 20 条窗口逐步展开，
            // 不能让一次超采样把首屏从 20 条直接放大到 50 条。
            recentSessions: WorkspaceSessionPresentation.visibleSessions(
                loadedSessions,
                limit: visibleLimit
            ),
            unreadHistorySessionIDs: sessionStore.unreadHistorySessionIDs,
            sessionLoadState: loadState,
            hasInitialSessionContent: cachedPageState?.hasLoadedFirstPage == true || !storedRuntimeSessions.isEmpty,
            canLoadMoreSessions: WorkspaceSessionPresentation.canLoadMore(
                loadedCount: loadedSessions.count,
                visibleLimit: visibleLimit,
                remoteHasMore: cachedPageState?.hasMore == true
            ),
            selectedRuntime: $selectedSessionRuntime,
            claudeChannelAvailable: sessionStore.hasClaudeRuntimeChannel,
            currentDate: currentDate,
            onRefreshSessions: {
                Task {
                    await refreshWorkspaceSessions(project: project, presentationKey: presentationKey)
                }
            },
            onLoadMoreSessions: {
                await loadMoreWorkspaceSessions(project: project, presentationKey: presentationKey)
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
        if case .failed = catalogLoad.state { return L10n.text("ui.unable_to_load_workspace") }
        return L10n.text("ui.no_workspace_yet")
    }

    private var emptyWorkspaceSymbol: String {
        if case .failed = catalogLoad.state { return "exclamationmark.triangle" }
        return "folder.badge.plus"
    }

    private var emptyWorkspaceMessage: String {
        if case .failed(let message) = catalogLoad.state { return message }
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
        if let selectedWorkspaceID {
            let retainedID = sessionStore.retainedWorkspaceID(for: selectedWorkspaceID)
            if projects.contains(where: { $0.id == retainedID }) {
                self.selectedWorkspaceID = retainedID
                return
            }
        }
        selectedWorkspaceID = sessionStore.selectedProjectID.flatMap { selectedID in
            projects.contains(where: { $0.id == selectedID }) ? selectedID : nil
        } ?? projects.first?.id
    }

    private func removeWorkspace(_ project: AgentProject) {
        guard selectedWorkspaceID != project.id else { return }
        runtimeSessionPagesByKey = runtimeSessionPagesByKey.filter { $0.key.workspaceID != project.id }
        sessionLoadStates = sessionLoadStates.filter { $0.key.workspaceID != project.id }
        sessionLoadInvocationTokens.remove { $0.workspaceID == project.id }
        workspaceSessionVisibleLimitByKey = workspaceSessionVisibleLimitByKey.filter {
            $0.key.workspaceID != project.id
        }
        sessionStore.forgetWorkspace(project)
    }

    private func workspaceSessionPresentationKey(for project: AgentProject) -> WorkspaceSessionPresentationKey {
        WorkspaceSessionPresentationKey(
            hostScope: appStore.activeHostScope,
            workspaceID: project.id,
            workspacePath: project.path,
            runtimeProvider: selectedSessionRuntime.runtimeProvider
        )
    }

    private func workspaceSessionVisibleLimit(for key: WorkspaceSessionPresentationKey) -> Int {
        max(
            SessionStore.initialSessionPageLimit,
            workspaceSessionVisibleLimitByKey[key] ?? SessionStore.initialSessionPageLimit
        )
    }

    private func loadMoreWorkspaceSessions(
        project: AgentProject,
        presentationKey: WorkspaceSessionPresentationKey
    ) async {
        let currentVisibleLimit = workspaceSessionVisibleLimit(for: presentationKey)
        let targetVisibleLimit = WorkspaceSessionPresentation.nextVisibleLimit(
            current: currentVisibleLimit,
            pageSize: SessionStore.expandedSessionPageLimit
        )
        var pageState = runtimeSessionPagesByKey[presentationKey] ?? WorkspaceRuntimeSessionPageState()
        let loadedCount = pageState.sessions.count
        if WorkspaceSessionPresentation.shouldRequestRemotePage(
            loadedCount: loadedCount,
            targetVisibleLimit: targetVisibleLimit,
            remoteHasMore: pageState.hasMore
        ) {
            do {
                let page = try await sessionStore.workspaceRuntimeSessionsPage(
                    projectID: project.id,
                    runtimeProvider: presentationKey.runtimeProvider,
                    cursor: pageState.nextCursor,
                    limit: SessionStore.expandedSessionPageLimit,
                    excludingListableSessionIDs: Set(pageState.sessions.map(\.id))
                )
                pageState.append(page)
                runtimeSessionPagesByKey[presentationKey] = pageState
                sessionLoadStates[presentationKey] = .loaded
            } catch {
                guard !isCancellationError(error) else { return }
                sessionLoadStates[presentationKey] = .failed(error.localizedDescription)
            }
        }

        guard appStore.activeHostScope == presentationKey.hostScope,
              let currentProject = sessionStore.sidebarProjects.first(where: { $0.id == project.id }),
              currentProject.path == presentationKey.workspacePath
        else {
            return
        }
        workspaceSessionVisibleLimitByKey[presentationKey] = WorkspaceSessionPresentation.committedVisibleLimit(
            current: currentVisibleLimit,
            target: targetVisibleLimit,
            loadedCount: runtimeSessionPagesByKey[presentationKey]?.sessions.count ?? pageState.sessions.count
        )
    }

    private func refreshCatalog(forceGitSummary: Bool = false) async {
        let invocationID = catalogLoad.begin()
        do {
            try await sessionStore.refreshWorkspaceCatalog()
            guard catalogLoad.isCurrent(invocationID) else {
                return
            }
            guard !Task.isCancelled else {
                catalogLoad.complete(
                    invocationID,
                    result: .cancelled,
                    hasCachedProjects: !sessionStore.sidebarProjects.isEmpty
                )
                return
            }
            catalogLoad.complete(
                invocationID,
                result: .loaded,
                hasCachedProjects: !sessionStore.sidebarProjects.isEmpty
            )
            await sessionStore.refreshWorkspaceGitSummaries(
                for: sessionStore.sidebarProjects,
                force: forceGitSummary
            )
        } catch {
            catalogLoad.complete(
                invocationID,
                result: isCancellationError(error) ? .cancelled : .failed(error.localizedDescription),
                hasCachedProjects: !sessionStore.sidebarProjects.isEmpty
            )
        }
    }

    private func refreshWorkspaceContent(projectID: String) async {
        await refreshCatalog(forceGitSummary: true)
        guard !Task.isCancelled,
              selectedWorkspaceID == projectID,
              let project = sessionStore.sidebarProjects.first(where: { $0.id == projectID })
        else {
            return
        }
        let presentationKey = workspaceSessionPresentationKey(for: project)
        await refreshWorkspaceSessions(project: project, presentationKey: presentationKey)
    }

    private func refreshWorkspaceSessions(
        project: AgentProject,
        presentationKey: WorkspaceSessionPresentationKey
    ) async {
        // 每个 Runtime 独立占有提交 token；切换筛选不会让旧请求覆盖当前 Runtime 的缓存。
        let invocationID = sessionLoadInvocationTokens.begin(for: presentationKey)
        sessionLoadStates[presentationKey] = .loading
        do {
            let page = try await sessionStore.workspaceRuntimeSessionsPage(
                projectID: project.id,
                runtimeProvider: presentationKey.runtimeProvider,
                cursor: nil,
                limit: SessionStore.initialSessionPageLimit
            )
            guard sessionLoadInvocationTokens.isCurrent(invocationID, for: presentationKey) else {
                return
            }
            guard !Task.isCancelled,
                  appStore.activeHostScope == presentationKey.hostScope,
                  sessionStore.sidebarProjects.contains(where: {
                      $0.id == project.id && $0.path == presentationKey.workspacePath
                  })
            else {
                sessionLoadStates[presentationKey] = fallbackSessionLoadState(for: presentationKey)
                return
            }
            var nextState = WorkspaceRuntimeSessionPageState()
            nextState.replace(with: page)
            runtimeSessionPagesByKey[presentationKey] = nextState
            workspaceSessionVisibleLimitByKey[presentationKey] = SessionStore.initialSessionPageLimit
            sessionLoadStates[presentationKey] = .loaded
        } catch {
            guard sessionLoadInvocationTokens.isCurrent(invocationID, for: presentationKey) else {
                return
            }
            switch workspaceSessionLoadFailureDisposition(error) {
            case .cancelled:
                sessionLoadStates[presentationKey] = fallbackSessionLoadState(for: presentationKey)
            case .failed(let message):
                sessionLoadStates[presentationKey] = .failed(message)
            }
        }
    }

    private func sessionLoadState(for key: WorkspaceSessionPresentationKey) -> WorkspaceSessionLoadState {
        sessionLoadStates[key] ?? fallbackSessionLoadState(for: key)
    }

    private func fallbackSessionLoadState(for key: WorkspaceSessionPresentationKey) -> WorkspaceSessionLoadState {
        runtimeSessionPagesByKey[key]?.hasLoadedFirstPage == true ? .loaded : .idle
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

private struct WorkspaceLibraryCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let project: AgentProject
    let profileID: String
    @ObservedObject var appearanceStore: WorkspaceAppearanceStore
    let iconStyle: WorkspaceIconStyle
    let displayedCharacter: WorkspaceCharacterIcon
    let displayedEmoji: String
    let unavailableCharacterIDs: Set<String>
    let unavailableEmoji: Set<String>
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
    let onOpenGitChanges: () -> Void
    let onConfirmRemove: () -> Void
    @State private var isPresentingIconPicker = false
    @State private var isPresentingRemoveConfirmation = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                cardContent
            }
            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
            .accessibilityLabel(accessibilitySummary)

            Menu {
                Button(action: onOpenGitChanges) {
                    Label(L10n.text("ui.git_changes"), systemImage: "doc.text.magnifyingglass")
                }
                .disabled(gitSummary?.isRepository == false)
                .accessibilityIdentifier("workspace.card.git.\(project.id)")

                if allowsCustomization {
                    Button {
                        isPresentingIconPicker = true
                    } label: {
                        Label(L10n.text("ui.workspace_icon"), systemImage: iconStyle == .emoji ? "face.smiling" : "person.crop.square")
                    }
                }

                if !isSelected {
                    Button(role: .destructive) {
                        isPresentingRemoveConfirmation = true
                    } label: {
                        Label(L10n.text("ui.remove_directory"), systemImage: "xmark.circle")
                    }
                    .accessibilityIdentifier("workspace.remove.request.\(project.id)")
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "ellipsis.circle")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(isSelected ? tokens.secondaryText : tokens.tertiaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .accessibilityLabel(L10n.text("ui.workspace_actions"))
            .accessibilityIdentifier("workspace.card.actions.\(project.id)")
            // iPad 会把 confirmationDialog 适配成 popover；必须挂在真实的 44pt 操作源上，
            // 让系统在旋转和分栏宽度变化时从当前卡片计算箭头与安全区域，而不是使用整页根视图。
            .confirmationDialog(
                L10n.text("ui.remove_directory"),
                isPresented: $isPresentingRemoveConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.format("ui.remove_directory_value", project.name), role: .destructive) {
                    onConfirmRemove()
                }
                .accessibilityIdentifier("workspace.remove.confirm.\(project.id)")
                Button(L10n.text("ui.cancel"), role: .cancel) {
                    isPresentingRemoveConfirmation = false
                }
            } message: {
                Text(L10n.text("ui.removing_a_directory_only_removes_it_from_the_workspace"))
            }
            .padding(.top, 4)
            .padding(.trailing, 2)

            if allowsCustomization {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Button {
                            isPresentingIconPicker = true
                        } label: {
                            Color.clear
                                .frame(width: 52, height: 52)
                                .contentShape(WorkspaceIconMeeGoShape())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("workspace.card.icon.\(project.id)")
                        .accessibilityLabel(
                            L10n.format(
                                "ui.change_workspace_icon_value",
                                project.name,
                                currentIconName
                            )
                        )
                        .popover(isPresented: $isPresentingIconPicker, arrowEdge: .top) {
                            iconPicker
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
                iconTile

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

    @ViewBuilder
    private var iconTile: some View {
        if iconStyle.usesCharacters {
            Image(displayedCharacter.assetName)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(WorkspaceIconMeeGoShape())
                .overlay {
                    // 角色图统一使用暖白底；这里只提供适配明暗模式的轮廓，不再叠加随机主题色。
                    WorkspaceIconMeeGoShape()
                        .stroke(tokens.border.opacity(colorScheme == .dark ? 0.72 : 0.42), lineWidth: 0.75)
                }
                .overlay(alignment: .bottomTrailing) {
                    runningIndicator
                }
                .opacity(isUnavailable ? 0.62 : 1)
                .accessibilityHidden(true)
        } else {
            let palette: [Color] = [
                Color(red: 0.91, green: 0.63, blue: 0.48),
                Color(red: 0.47, green: 0.67, blue: 0.78),
                Color(red: 0.76, green: 0.64, blue: 0.42),
                Color(red: 0.88, green: 0.72, blue: 0.34),
                Color(red: 0.64, green: 0.70, blue: 0.48),
                Color(red: 0.72, green: 0.53, blue: 0.72)
            ]
            let tint = palette[
                WorkspaceAppearanceStore.tintIndex(for: displayedEmoji, count: palette.count)
            ]

            Text(displayedEmoji)
                .font(.system(size: 30))
                .frame(width: 52, height: 52)
                .background(
                    tint.opacity(colorScheme == .dark ? 0.30 : 0.18),
                    in: WorkspaceIconMeeGoShape()
                )
                .overlay(alignment: .bottomTrailing) {
                    runningIndicator
                }
                .opacity(isUnavailable ? 0.62 : 1)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var runningIndicator: some View {
        if hasRunningSession {
            Circle()
                .fill(tokens.secondaryText)
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

    @ViewBuilder
    private var iconPicker: some View {
        if iconStyle.usesCharacters {
            WorkspaceCharacterPicker(
                project: project,
                profileID: profileID,
                appearanceStore: appearanceStore,
                style: iconStyle,
                currentCharacterID: displayedCharacter.id,
                unavailableCharacterIDs: unavailableCharacterIDs,
                tokens: tokens
            )
        } else {
            WorkspaceEmojiPicker(
                project: project,
                profileID: profileID,
                appearanceStore: appearanceStore,
                currentEmoji: displayedEmoji,
                unavailableEmoji: unavailableEmoji,
                tokens: tokens
            )
        }
    }

    private var currentIconName: String {
        iconStyle.usesCharacters ? displayedCharacter.name : displayedEmoji
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
            // 运行和领先状态在主页只需可识别，不再与导航选中态争夺紫色焦点。
            return tokens.secondaryText
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

private struct WorkspaceCharacterPicker: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: AgentProject
    let profileID: String
    @ObservedObject var appearanceStore: WorkspaceAppearanceStore
    let style: WorkspaceIconStyle
    let currentCharacterID: String
    let unavailableCharacterIDs: Set<String>
    let tokens: ThemeTokens

    private let columns = Array(repeating: GridItem(.fixed(52), spacing: 8), count: 5)

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
                ForEach(WorkspaceAppearanceStore.characters(for: style)) { character in
                    let isUnavailable = unavailableCharacterIDs.contains(character.id)
                    Button {
                        appearanceStore.setCustomCharacterID(
                            character.id,
                            style: style,
                            profileID: profileID,
                            projectID: project.id
                        )
                        dismiss()
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(character.assetName)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 52, height: 52)
                                .clipShape(WorkspaceIconMeeGoShape())
                                .overlay {
                                    WorkspaceIconMeeGoShape()
                                        .stroke(tokens.border.opacity(0.5), lineWidth: 0.75)
                                }
                            if currentCharacterID == character.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(themeStore.uiFont(size: 12, weight: .semibold))
                                    .foregroundStyle(tokens.primaryAction)
                                    .background(tokens.surface, in: Circle())
                            }
                        }
                    }
                    .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                    .disabled(isUnavailable)
                    .opacity(isUnavailable ? 0.36 : 1)
                    .accessibilityIdentifier("workspace.character.\(character.id)")
                    .accessibilityLabel(character.name)
                    .accessibilityAddTraits(currentCharacterID == character.id ? .isSelected : [])
                }
            }

            Button {
                appearanceStore.setCustomCharacterID(nil, profileID: profileID, projectID: project.id)
                dismiss()
            } label: {
                Label(L10n.text("ui.restore_default_appearance"), systemImage: "arrow.counterclockwise")
            }
            .font(themeStore.uiFont(.callout, weight: .medium))
            .disabled(
                appearanceStore.customCharacterID(profileID: profileID, projectID: project.id) == nil
            )
        }
        .padding(18)
        .frame(width: 336)
        .background(tokens.surface)
        .accessibilityIdentifier("workspace.characterPicker")
    }

}

private struct WorkspaceEmojiPicker: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: AgentProject
    let profileID: String
    @ObservedObject var appearanceStore: WorkspaceAppearanceStore
    let currentEmoji: String
    let unavailableEmoji: Set<String>
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
                    let isUnavailable = unavailableEmoji.contains(emoji)
                    Button {
                        appearanceStore.setCustomEmoji(
                            emoji,
                            profileID: profileID,
                            projectID: project.id
                        )
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
                    .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                    .disabled(isUnavailable)
                    .opacity(isUnavailable ? 0.36 : 1)
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
        .accessibilityIdentifier("workspace.emojiPicker")
        .onAppear {
            customInput = appearanceStore.customEmoji(
                profileID: profileID,
                projectID: project.id
            ) ?? ""
        }
    }

    private func applyCustomEmoji() {
        guard let emoji = WorkspaceAppearanceStore.normalizedEmoji(customInput) else {
            validationMessage = L10n.text("ui.enter_one_valid_emoji")
            return
        }
        guard !unavailableEmoji.contains(emoji) else {
            validationMessage = L10n.text("ui.emoji_already_used")
            return
        }
        appearanceStore.setCustomEmoji(emoji, profileID: profileID, projectID: project.id)
        dismiss()
    }
}

private struct WorkspaceRuntimePicker: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    @Binding var selection: WorkspaceSessionRuntimeChoice
    let claudeChannelAvailable: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 0) {
            ForEach(WorkspaceSessionRuntimeChoice.allCases) { choice in
                let isSelected = selection == choice
                let isAvailable = choice != .claude || claudeChannelAvailable

                Button {
                    guard isAvailable else { return }
                    selection = choice
                } label: {
                    HStack(spacing: 6) {
                        Image(choice.brandAssetName)
                            .resizable()
                            .renderingMode(.original)
                            .scaledToFit()
                            .frame(width: 17, height: 17)
                            .accessibilityHidden(true)

                        Text(choice.listTitle)
                            .font(themeStore.uiFont(.subheadline, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? tokens.primaryAction : tokens.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 44, minHeight: 36)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(tokens.surface)
                                .shadow(color: Color.black.opacity(0.08), radius: 2, y: 1)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!isAvailable)
                .opacity(isAvailable ? 1 : 0.42)
                .accessibilityLabel(choice.listTitle)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint(
                    isAvailable
                        ? L10n.text("ui.show_runtime_sessions_hint")
                        : L10n.text("ui.runtime_unavailable_hint")
                )
            }
        }
        .padding(4)
        .frame(minHeight: 44)
        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(tokens.border.opacity(0.72), lineWidth: 1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("ui.runtime_provider"))
        .accessibilityIdentifier("workspace.sessions.runtimePicker")
    }
}

private struct WorkspaceDetailView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var actionButtonHeight: CGFloat = 68
    @ScaledMetric(relativeTo: .caption) private var compactActionFontSize: CGFloat = 12
    @State private var isLoadingMoreSessions = false

    let recentSessions: [AgentSession]
    let unreadHistorySessionIDs: Set<SessionID>
    let sessionLoadState: WorkspaceSessionLoadState
    let hasInitialSessionContent: Bool
    let canLoadMoreSessions: Bool
    @Binding var selectedRuntime: WorkspaceSessionRuntimeChoice
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
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
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
            recentSessionsHeader(tokens: tokens)

            if sessionLoadState.isLoading, !hasInitialSessionContent {
                // 首屏窗口还没凑满：稳定显示骨架屏，避免切换时先渲染欠填的半截列表再逐批变多。
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
                        excludingSessionIDs: sessionStore.pinnedSessionIDs,
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
                        .sessionRowActions(session)
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
                                        .font(themeStore.uiFont(size: compactActionFontSize, weight: .semibold))
                                }
                                Text(isLoadingMoreSessions ? L10n.text("ui.loading") : L10n.text("ui.show_more"))
                            }
                            .font(themeStore.uiFont(size: compactActionFontSize, weight: .semibold))
                            .foregroundStyle(tokens.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoadingMoreSessions)
                        .accessibilityLabel(
                            isLoadingMoreSessions
                                ? L10n.text("ui.loading")
                                : L10n.text("ui.show_more")
                        )
                        .accessibilityIdentifier("workspace.sessions.loadMore")
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

    private func recentSessionsHeader(tokens: ThemeTokens) -> some View {
        let title = Text(L10n.text("ui.recent_conversations"))
            .font(themeStore.uiFont(.headline, weight: .semibold))
            .foregroundStyle(tokens.primaryText)

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                title
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                WorkspaceRuntimePicker(
                    selection: $selectedRuntime,
                    claudeChannelAvailable: claudeChannelAvailable
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                title
                WorkspaceRuntimePicker(
                    selection: $selectedRuntime,
                    claudeChannelAvailable: claudeChannelAvailable
                )
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
        let statusTone = recentSessionStatusColor(for: status.tone, tokens: tokens)

        return HStack(spacing: 12) {
            SessionRuntimeIcon(
                session: session,
                size: 18,
                isActive: session.isRunning
            )
                .frame(width: 34, height: 34)
                .background(
                    tokens.elevatedSurface.opacity(session.isRunning ? 0.82 : 0.54),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if sessionStore.isSessionPinned(session.id) {
                        SessionPinnedBadge(compact: true)
                    }

                    Text(session.title)
                        .font(themeStore.uiFont(.callout, weight: .medium))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if unreadHistorySessionIDs.contains(session.id) {
                        SessionUnreadIndicator()
                    }
                }

                HStack(spacing: 6) {
                    if let branch = session.gitBranchName {
                        HStack(spacing: 4) {
                            SessionBranchIcon(size: 10)
                                .foregroundStyle(tokens.tertiaryText)
                                .accessibilityHidden(true)

                            Text(branch)
                                .foregroundStyle(tokens.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(L10n.text("ui.branch")) \(branch)")
                    }

                    if shouldShowRecentSessionStatus(session, status: status) {
                        HStack(spacing: 4) {
                            if shouldShowRecentSessionSpinner(session, status: status) {
                                // 只用系统小菊花表达持续执行；待处理和失败状态依靠文字与颜色，
                                // 避免把“需要用户动作”误读为仍在自动运行。
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(statusTone)
                            }

                            Text(status.title)
                        }
                        .foregroundStyle(statusTone)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(status.title)
                    }
                }
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
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
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            unreadHistorySessionIDs.contains(session.id)
                ? L10n.text("ui.unread_result")
                : ""
        )
    }

    private func shouldShowRecentSessionStatus(
        _ session: AgentSession,
        status: AgentSessionDisplayStatus
    ) -> Bool {
        session.isRunning || status.tone == .warning || status.tone == .danger
    }

    private func shouldShowRecentSessionSpinner(
        _ session: AgentSession,
        status: AgentSessionDisplayStatus
    ) -> Bool {
        session.isRunning && status.tone == .active
    }

    private func recentSessionStatusColor(
        for tone: AgentSessionStatusTone,
        tokens: ThemeTokens
    ) -> Color {
        switch tone {
        case .warning:
            return tokens.warning
        case .danger:
            return .red
        case .active, .complete, .neutral:
            // 主页的运行/完成信息属于次级元数据；紫色只留给导航与当前工作区。
            return tokens.secondaryText
        }
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
