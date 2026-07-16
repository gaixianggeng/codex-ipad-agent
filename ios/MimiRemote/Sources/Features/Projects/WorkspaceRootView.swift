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
            return "新建 Codex 会话"
        case .claude:
            return "新建 Claude Code 会话"
        }
    }

    var systemImage: String {
        switch self {
        case .codex:
            return "plus.circle"
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

    static func minimumContentWidth(viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - horizontalPadding * 2)
    }
}

/// 工作区只维护本地浏览选择。只有用户明确进入会话或新建会话时，才交给 SessionStore 改变活动上下文。
struct WorkspaceRootView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let onOpenInSessions: (AgentProject) -> Void
    let onStartSession: (AgentProject, WorkspaceSessionRuntimeChoice) -> Void
    let onOpenSession: (AgentSession) -> Void
    let embedsNavigationStack: Bool

    @State private var selectedWorkspaceID: String?
    @State private var catalogState: CatalogState = .idle
    @State private var sessionLoadStates: [String: WorkspaceSessionLoadState] = [:]
    @State private var isPresentingOpenWorkspace = false

    init(
        onOpenInSessions: @escaping (AgentProject) -> Void,
        onStartSession: @escaping (AgentProject, WorkspaceSessionRuntimeChoice) -> Void,
        onOpenSession: @escaping (AgentSession) -> Void = { _ in },
        embedsNavigationStack: Bool = true
    ) {
        self.onOpenInSessions = onOpenInSessions
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
        .background(tokens.background.ignoresSafeArea())
    }

    private func navigationContent(tokens: ThemeTokens) -> some View {
        workspaceBrowser(tokens: tokens)
            .navigationTitle("工作区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresentingOpenWorkspace = true
                    } label: {
                        Label("打开目录", systemImage: "folder.badge.plus")
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
                    ContentUnavailableView("请选择工作区", systemImage: "folder")
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

            ProgressView("正在加载工作区")
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
                    Label(isFailure ? "重新加载" : "打开目录", systemImage: isFailure ? "arrow.clockwise" : "folder.badge.plus")
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
                                    project: AgentProject(id: "loading-\(index)", name: "正在加载工作区", path: "/Users/you/code/project"),
                                    sessionCount: 0,
                                    worktreeCount: 0,
                                    isUnavailable: false,
                                    isSelected: false,
                                    tokens: tokens
                                ) {}
                                .frame(width: 300)
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
                                }
                                .frame(width: 300)
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
            .frame(height: 150)
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
        .accessibilityLabel("工作区列表")
    }

    private func workspaceDetail(project: AgentProject) -> some View {
        WorkspaceDetailView(
            recentSessions: Array(sessionStore.sessions(forProjectID: project.id).prefix(5)),
            sessionLoadState: sessionLoadState(for: project.id),
            isShownInSessions: sessionStore.isWorkspaceShownInSessions(project.id),
            claudeChannelAvailable: sessionStore.hasClaudeRuntimeChannel,
            onRefreshSessions: {
                Task {
                    await refreshWorkspaceSessions(projectID: project.id)
                }
            },
            onToggleSessionVisibility: {
                sessionStore.toggleWorkspaceInSessions(project)
            },
            onOpenInSessions: {
                onOpenInSessions(project)
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
        if case .failed = catalogState { return "无法加载工作区" }
        return "还没有工作区"
    }

    private var emptyWorkspaceSymbol: String {
        if case .failed = catalogState { return "exclamationmark.triangle" }
        return "folder.badge.plus"
    }

    private var emptyWorkspaceMessage: String {
        if case .failed(let message) = catalogState { return message }
        return "打开目录后，可以在这里浏览项目和创建会话。"
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
    case secondary
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

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isUnavailable ? "folder.badge.questionmark" : "folder.fill")
                        .font(themeStore.uiFont(size: 22, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isUnavailable ? tokens.warning : tokens.primaryAction)
                        .frame(width: 44, height: 44)
                        .background((isUnavailable ? tokens.warning : tokens.primaryAction).opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
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
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.down")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(isSelected ? tokens.primaryAction : tokens.tertiaryText)
                }

                HStack(spacing: 8) {
                    metric("\(sessionCount)", title: "会话", systemImage: "bubble.left.and.bubble.right")
                    metric("\(worktreeCount)", title: "Worktree", systemImage: "arrow.triangle.branch")
                    Spacer(minLength: 0)
                    Label(isUnavailable ? "需要重试" : "可访问", systemImage: isUnavailable ? "exclamationmark.triangle" : "checkmark.circle.fill")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(isUnavailable ? tokens.warning : tokens.success)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .background(isSelected ? tokens.selectionFill : tokens.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isSelected ? tokens.primaryAction : tokens.border.opacity(0.72),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("工作区 \(project.name)，\(sessionCount) 个会话\(isSelected ? "，已选择" : "")")
    }

    private func metric(_ value: String, title: String, systemImage: String) -> some View {
        Label("\(value) \(title)", systemImage: systemImage)
            .font(themeStore.uiFont(.caption, weight: .medium))
            .foregroundStyle(tokens.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tokens.elevatedSurface.opacity(0.66), in: Capsule())
    }
}

private struct WorkspaceDetailView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let recentSessions: [AgentSession]
    let sessionLoadState: WorkspaceSessionLoadState
    let isShownInSessions: Bool
    let claudeChannelAvailable: Bool
    let onRefreshSessions: () -> Void
    let onToggleSessionVisibility: () -> Void
    let onOpenInSessions: () -> Void
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
            Text("快捷操作")
                .font(themeStore.uiFont(.subheadline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)

            // 创建会话是工作区页的主任务；固定为一行两列，避免 iPad 上出现“三加一”的孤立按钮。
            LazyVGrid(columns: actionColumns, spacing: 12) {
                ForEach(WorkspaceSessionRuntimeChoice.available(claudeChannelAvailable: claudeChannelAvailable)) { choice in
                    actionButton(
                        title: choice.title,
                        subtitle: choice == .codex ? "使用默认运行时开始" : "使用 Claude Code 运行时开始",
                        systemImage: choice.systemImage,
                        emphasis: choice == .codex ? .primary : .accented,
                        tokens: tokens
                    ) {
                        // thread 创建时就绑定 runtime；这里必须把用户选择一路传到 SessionStore。
                        onStartSession(choice)
                    }
                }
            }

            // 导航和侧栏可见性属于辅助操作，降低视觉权重但保留完整 44pt 以上触控区域。
            LazyVGrid(columns: actionColumns, spacing: 12) {
                actionButton(
                    title: "在会话中打开",
                    systemImage: "bubble.left.and.bubble.right",
                    emphasis: .secondary,
                    tokens: tokens,
                    action: onOpenInSessions
                )

                actionButton(
                    title: isShownInSessions ? "从会话侧栏隐藏" : "显示在会话侧栏",
                    systemImage: isShownInSessions ? "eye.slash" : "eye",
                    emphasis: .secondary,
                    tokens: tokens,
                    action: onToggleSessionVisibility
                )
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
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        emphasis: WorkspaceActionEmphasis,
        tokens: ThemeTokens,
        action: @escaping () -> Void
    ) -> some View {
        let foreground = actionForeground(emphasis: emphasis, tokens: tokens)
        let background = actionBackground(emphasis: emphasis, tokens: tokens)
        let border = actionBorder(emphasis: emphasis, tokens: tokens)
        let cornerRadius: CGFloat = emphasis == .secondary ? 12 : 16

        return Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(themeStore.uiFont(size: emphasis == .secondary ? 17 : 19, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(foreground)
                    .frame(width: emphasis == .secondary ? 34 : 40, height: emphasis == .secondary ? 34 : 40)
                    .background(actionIconBackground(emphasis: emphasis, tokens: tokens), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
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
            .frame(maxWidth: .infinity, minHeight: emphasis == .secondary ? 52 : 72, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(border, lineWidth: emphasis == .accented ? 1.2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(WorkspaceActionPressButtonStyle(reduceMotion: reduceMotion))
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
        case .secondary:
            return tokens.elevatedSurface.opacity(0.58)
        }
    }

    private func actionIconBackground(emphasis: WorkspaceActionEmphasis, tokens: ThemeTokens) -> Color {
        switch emphasis {
        case .primary:
            return tokens.primaryActionForeground.opacity(0.15)
        case .accented:
            return tokens.accentSoft
        case .secondary:
            return tokens.surface.opacity(0.82)
        }
    }

    private func actionBorder(emphasis: WorkspaceActionEmphasis, tokens: ThemeTokens) -> Color {
        switch emphasis {
        case .primary:
            return tokens.primaryAction.opacity(0.92)
        case .accented:
            return tokens.primaryAction.opacity(0.24)
        case .secondary:
            return tokens.border.opacity(0.58)
        }
    }

    private func recentSessionsSection(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近会话")
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
                        Text(sessionLoadState.isLoading ? "加载中" : "刷新")
                    }
                    .font(themeStore.uiFont(.caption, weight: .medium))
                    .foregroundStyle(tokens.primaryAction)
                }
                .buttonStyle(.plain)
                .disabled(sessionLoadState.isLoading)
                .accessibilityLabel(sessionLoadState.isLoading ? "正在加载最近会话" : "刷新最近会话")
            }

            if recentSessions.isEmpty, sessionLoadState.isLoading {
                recentSessionPlaceholders(tokens: tokens)
            } else if recentSessions.isEmpty, case .failed(let message) = sessionLoadState {
                ContentUnavailableView {
                    Label("无法加载会话", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("重新加载", action: onRefreshSessions)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(tokens.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if recentSessions.isEmpty {
                ContentUnavailableView("还没有会话", systemImage: "bubble.left.and.bubble.right", description: Text("在这个工作区新建会话后，会显示在这里。"))
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
        .accessibilityLabel("正在加载最近会话")
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
        return provider.lowercased().contains("claude") ? "Claude Code" : "Codex"
    }

    private func sessionTimeText(for session: AgentSession) -> String {
        guard let date = session.updatedAt ?? session.createdAt else { return "" }
        if Calendar.current.isDateInToday(date) {
            return Self.sessionTimeFormatter.string(from: date)
        }
        return Self.sessionDateFormatter.string(from: date)
    }

    private static let sessionTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let sessionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}
