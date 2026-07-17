import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var notificationResponseAdapter: SessionNotificationResponseAdapter
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingLogInspector = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @SceneStorage("root.selectedAppTab") private var selectedAppTabRawValue = AppTab.sessions.rawValue
    @SceneStorage("root.lastSessionSnapshot") private var lastSessionSnapshot = ""
    @AppStorage("runtime.keepAwakeWhileRunning") private var keepAwakeWhileRunning = false
    @State private var notificationRouteAlertMessage: String?
    @State private var hasCompletedInitialBootstrap = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if appStore.canEnterWorkbench {
                appShell
            } else {
                SettingsView(isInitialSetup: true)
                    .environment(\.themeSystemColorScheme, colorScheme)
            }
        }
        .task {
#if targetEnvironment(macCatalyst)
            // Catalyst 先完成本机选路，再创建首批 REST/WebSocket client；否则并行 bootstrap
            // 可能已经拿 Tailscale 地址建好 runtime，导致本次启动无法真正切到 loopback。
            await appStore.preflightConnection()
#endif
            await sessionStore.bootstrap(restoring: decodedSessionRestoreSnapshot)
            hasCompletedInitialBootstrap = true
        }
        .task {
#if targetEnvironment(macCatalyst)
            // 已在上面的有序启动任务中完成。
#else
            // 冷启动先并行探测真实控制面和 WebSocket，设置页无需用户手动测试即可看到连接状态。
            await appStore.preflightConnection()
#endif
        }
        .task(id: notificationRouteTaskID) {
            // 冷启动恢复必须先结束，否则 restoreSessionIfPossible 可能覆盖通知刚选中的会话。
            // bootstrap 完成前不 consume；完成状态变化会连同 pending route 重新触发此 task。
            guard hasCompletedInitialBootstrap,
                  let route = notificationResponseAdapter.pendingRoute else { return }
            // 先消费再做网络操作；新点击可独立入队，不会被旧任务结束时误清。
            notificationResponseAdapter.consume(route)
            await handleNotificationRoute(route)
        }
        .task(id: scenePhase == .active ? sessionStore.selectedProjectID : nil) {
            guard scenePhase == .active else {
                return
            }
            await sessionStore.pollSelectedProjectSessionsWhileVisible()
        }
        .onAppear(perform: applyIdleTimerPolicy)
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            applyIdleTimerPolicy()
            if phase == .background {
                sessionStore.suspendForBackground()
                return
            }
            guard phase == .active else {
                return
            }
            Task {
                await sessionStore.resumeFromForeground()
            }
        }
        .onChange(of: keepAwakeWhileRunning) { _, _ in
            applyIdleTimerPolicy()
        }
        .onChange(of: sessionStore.selectedSessionID) { _, _ in
            applyIdleTimerPolicy()
        }
        .onChange(of: sessionStore.selectedSession) { _, session in
            guard let session else { return }
            let snapshot = SessionRestoreSnapshot(endpoint: appStore.endpoint, session: session)
            if let data = try? JSONEncoder().encode(snapshot) {
                lastSessionSnapshot = data.base64EncodedString()
            }
        }
        .onChange(of: sessionStore.selectedSession?.status) { _, _ in
            applyIdleTimerPolicy()
        }
        .onChange(of: sessionStore.webSocketStatus) { _, _ in
            applyIdleTimerPolicy()
        }
        .environment(\.themeSystemColorScheme, colorScheme)
        .preferredColorScheme(themeStore.preferredColorScheme)
        .tint(tokens.accent)
        .background(tokens.background.ignoresSafeArea())
        .alert("无法打开通知", isPresented: notificationRouteAlertBinding) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(notificationRouteAlertMessage ?? "请稍后重试。")
        }
    }

    private var notificationRouteAlertBinding: Binding<Bool> {
        Binding(
            get: { notificationRouteAlertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    notificationRouteAlertMessage = nil
                }
            }
        )
    }

    private var notificationRouteTaskID: NotificationRouteTaskID {
        NotificationRouteTaskID(
            route: notificationResponseAdapter.pendingRoute,
            hasCompletedInitialBootstrap: hasCompletedInitialBootstrap
        )
    }

    private func handleNotificationRoute(_ route: SessionNotificationRoute) async {
        switch await sessionStore.openSessionFromNotification(route) {
        case .opened:
            selectedAppTabRawValue = AppTab.sessions.rawValue
        case .requiresProfileSwitch(let displayName):
            if let displayName {
                notificationRouteAlertMessage = "此通知来自“\(displayName)”，请先在设置中切换到该连接档案。"
            } else {
                notificationRouteAlertMessage = "此通知来自其他 Mac，请先在设置中切换到对应连接档案。"
            }
        case .unavailable(let message):
            notificationRouteAlertMessage = message
        case .ignored:
            break
        }
    }

    private func applyIdleTimerPolicy() {
        // 只在前台且用户明确开启时保持常亮；离开运行会话后立即恢复系统默认，避免静默耗电。
        UIApplication.shared.isIdleTimerDisabled = keepAwakeWhileRunning
            && scenePhase == .active
            && sessionStore.selectedSession?.isRunning == true
    }

    private var decodedSessionRestoreSnapshot: SessionRestoreSnapshot? {
        guard let data = Data(base64Encoded: lastSessionSnapshot) else { return nil }
        return try? JSONDecoder().decode(SessionRestoreSnapshot.self, from: data)
    }

    private var selectedAppTab: AppTab {
        // v30 以前保存的“我的”入口并入设置，升级后不让用户落到不存在的 tab。
        if selectedAppTabRawValue == "profile" {
            return .settings
        }
        return AppTab(rawValue: selectedAppTabRawValue) ?? .sessions
    }

    private var selectedAppTabBinding: Binding<AppTab> {
        Binding(
            get: { selectedAppTab },
            set: { selectedAppTabRawValue = $0.rawValue }
        )
    }

    private var appShell: some View {
        UnifiedWorkbenchShell(showingInspector: $showingLogInspector)
    }

    @ViewBuilder
    private func appTabContent(for tab: AppTab) -> some View {
        switch tab {
        case .sessions:
            mainLayout
        case .workspace:
            WorkspaceRootView(
                onOpenInSessions: { project in
                    Task {
                        await sessionStore.selectProject(project)
                        selectedAppTabRawValue = AppTab.sessions.rawValue
                    }
                },
                onStartSession: { project, runtimeChoice in
                    Task {
                        // Workspace 新入口也必须保留 runtime 选择，否则 Claude 会话会静默落到 Codex gateway。
                        await sessionStore.startNewSession(in: project, runtimeProvider: runtimeChoice.runtimeProvider)
                        selectedAppTabRawValue = AppTab.sessions.rawValue
                    }
                },
                onOpenSession: { session in
                    Task {
                        await sessionStore.selectSession(session)
                        selectedAppTabRawValue = AppTab.sessions.rawValue
                    }
                }
            )
                .environment(\.themeSystemColorScheme, colorScheme)
        case .settings:
            SettingsView(isInitialSetup: false, showsDoneButton: false)
                .environment(\.themeSystemColorScheme, colorScheme)
        }
    }

    private var mainLayout: some View {
        GeometryReader { proxy in
            let layout = WorkbenchLayout(containerWidth: proxy.size.width, horizontalSizeClass: horizontalSizeClass)

            if layout.usesCompactNavigation {
                compactLayout(layout: layout)
            } else {
                splitLayout(layout: layout)
            }
        }
        .background(themeStore.tokens(for: colorScheme).background.ignoresSafeArea())
        .overlay {
            initialConnectionOverlay
        }
    }

    @ViewBuilder
    private var initialConnectionOverlay: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        if appStore.isConfigured,
           sessionStore.sidebarProjects.isEmpty,
           sessionStore.selectedProjectID == nil,
           sessionStore.selectedSessionID == nil,
           sessionStore.isLoading || sessionStore.errorMessage != nil {
            VStack(spacing: 14) {
                if sessionStore.isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .tint(tokens.accent)
                    Text("正在连接 Mac 助手")
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text("如果刚启动 Tailscale 或 Mac 助手，这里会自动重试。")
                        .font(themeStore.uiFont(.callout))
                        .foregroundStyle(tokens.secondaryText)
                        .multilineTextAlignment(.center)
                } else {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(tokens.warning)
                    Text("无法连接 Mac 助手")
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(sessionStore.errorMessage ?? "请检查 Mac 助手和网络连接。")
                        .font(themeStore.uiFont(.callout))
                        .foregroundStyle(tokens.secondaryText)
                        .multilineTextAlignment(.center)
                    Button {
                        selectedAppTabRawValue = AppTab.settings.rawValue
                    } label: {
                        Label("打开设置", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tokens.border, lineWidth: 1)
            }
            .padding()
            .transition(.opacity)
        }
    }

    private func compactLayout(layout: WorkbenchLayout) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return NavigationStack {
            ProjectSidebarView(showsSessions: true, onOpenWorkspaceTab: {
                selectedAppTabRawValue = AppTab.workspace.rawValue
            })
                .navigationTitle("咪咪")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(isPresented: compactSessionDetailBinding) {
                    workspaceDetail(layout: layout)
                        // 手机详情页需要把纵向空间完整留给消息和输入区；返回列表后系统会自动恢复 Tab Bar。
                        .toolbar(.hidden, for: .tabBar)
                }
        }
        .themedWorkbenchNavigationChrome(tokens: tokens, colorScheme: themeStore.resolvedColorScheme(for: colorScheme))
        .onChange(of: sessionStore.selectedSessionID) { _, sessionID in
            if sessionID == nil {
                showingLogInspector = false
            }
        }
    }

    private func splitLayout(layout: WorkbenchLayout) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectSidebarView(showsSessions: true, onCollapseSidebar: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    columnVisibility = .detailOnly
                }
            }, onOpenWorkspaceTab: {
                selectedAppTabRawValue = AppTab.workspace.rawValue
            })
                // 侧栏本身用 Section header 呈现“项目”，隐藏大标题可以让项目树首屏更紧凑。
                .toolbar(.hidden, for: .navigationBar)
                .themedWorkbenchNavigationChrome(tokens: tokens, colorScheme: themeStore.resolvedColorScheme(for: colorScheme))
                // 侧栏宽度跟随窗口缩放，iPhone、iPad mini 和浮窗不会把详情区挤到只剩一条窄缝。
                .navigationSplitViewColumnWidth(
                    min: layout.projectColumn.min,
                    ideal: layout.projectColumn.ideal,
                    max: layout.projectColumn.max
                )
        } detail: {
            workspaceDetail(layout: layout)
        }
        .navigationSplitViewStyle(.balanced)
        .background(tokens.background.ignoresSafeArea())
        .themedWorkbenchNavigationChrome(tokens: tokens, colorScheme: themeStore.resolvedColorScheme(for: colorScheme))
        .onAppear {
            applyResponsiveColumnVisibility(for: layout)
        }
        .onChange(of: layout) { _, newLayout in
            applyResponsiveColumnVisibility(for: newLayout)
        }
        .onChange(of: sessionStore.selectedSessionID) { _, sessionID in
            if sessionID == nil {
                showingLogInspector = false
            }
            applyResponsiveColumnVisibility(for: layout)
        }
    }

    private func workspaceDetail(layout: WorkbenchLayout) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return WorkspaceView {
            selectedAppTabRawValue = AppTab.workspace.rawValue
        }
            .navigationTitle(sessionStore.selectedSession?.title ?? sessionStore.selectedProject?.name ?? "会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    AgentWorkbenchTitle(
                        maxWidth: layout.titleMaxWidth,
                        horizontalOffset: titleHorizontalOffset(layout: layout)
                    )
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if shouldShowDetailToolbarCluster {
                        detailToolbarCluster(layout: layout, tokens: tokens)
                    }
                }
            }
            .background(tokens.background.ignoresSafeArea())
            .themedWorkbenchNavigationChrome(tokens: tokens, colorScheme: themeStore.resolvedColorScheme(for: colorScheme))
            .sessionInspectorPresentation(isPresented: $showingLogInspector, layout: layout)
    }

    private func titleHorizontalOffset(layout: WorkbenchLayout) -> CGFloat {
        guard showingLogInspector, layout.usesAttachedInspector else {
            return 0
        }
        // SwiftUI inspector 会附着在 detail 右侧；系统 principal 默认按 detail+inspector 总宽居中。
        // 标题左移半个右栏宽度后，视觉中心重新落回中间对话区。
        return -(layout.inspectorColumn.ideal / 2)
    }

    // 顶部维护动作收成一个统一工具组，避免刷新、连接状态和详情入口各自漂浮。
    private var shouldShowDetailToolbarCluster: Bool {
        shouldShowDetailRefresh ||
            connectionBadgeSymbol != nil ||
            sessionStore.selectedSessionID != nil
    }

    private func detailToolbarCluster(layout: WorkbenchLayout, tokens: ThemeTokens) -> some View {
        HStack(spacing: 2) {
            detailRefreshControl(tokens: tokens)
            connectionBadgeControl(tokens: tokens)
            detailInspectorControl(layout: layout, tokens: tokens)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(tokens.elevatedSurface.opacity(0.58), in: Capsule())
        .overlay {
            Capsule()
                .stroke(tokens.border.opacity(0.5), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func detailRefreshControl(tokens: ThemeTokens) -> some View {
        if shouldShowDetailRefresh {
            if sessionStore.isLoading || sessionStore.isRefreshingSelectedSession {
                ProgressView()
                    .controlSize(.small)
                    .tint(tokens.secondaryText.opacity(0.8))
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("正在刷新")
            } else {
                detailToolbarButton(
                    systemImage: "arrow.clockwise",
                    accessibilityLabel: sessionStore.selectedSessionID == nil ? "刷新会话列表" : "刷新当前会话",
                    tokens: tokens
                ) {
                    Task { await sessionStore.refreshCurrentContext() }
                }
            }
        }
    }

    @ViewBuilder
    private func connectionBadgeControl(tokens: ThemeTokens) -> some View {
        if let symbol = connectionBadgeSymbol {
            Image(systemName: symbol)
                .font(themeStore.uiFont(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(connectionBadgeColor)
                .frame(width: 32, height: 32)
                .accessibilityLabel(sessionStore.connectionBadgeTitle ?? "连接状态")
        }
    }

    @ViewBuilder
    private func detailInspectorControl(layout: WorkbenchLayout, tokens: ThemeTokens) -> some View {
        if sessionStore.selectedSessionID != nil {
            detailToolbarButton(
                systemImage: "sidebar.right",
                accessibilityLabel: showingLogInspector ? "隐藏详情" : (layout.usesAttachedInspector ? "显示右侧详情" : "打开详情"),
                isActive: showingLogInspector,
                tokens: tokens
            ) {
                showingLogInspector.toggle()
            }
        }
    }

    private func detailToolbarButton(
        systemImage: String,
        accessibilityLabel: String,
        isActive: Bool = false,
        tokens: ThemeTokens,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? tokens.accent : tokens.secondaryText)
        .background(isActive ? tokens.selectionFill : Color.clear, in: Circle())
        .accessibilityLabel(accessibilityLabel)
    }

    private var shouldShowDetailRefresh: Bool {
        sessionStore.isLoading ||
            sessionStore.errorMessage != nil ||
            sessionStore.selectedProjectID != nil ||
            sessionStore.selectedSessionID != nil ||
            !sessionStore.sidebarProjects.isEmpty
    }

    private var connectionBadgeKind: StatusPill.Kind {
        if sessionStore.selectedSession?.isRunning == true {
            switch sessionStore.webSocketStatus {
            case .connected:
                return .success
            case .connecting:
                // 运行中但 WebSocket 还在握手，不算健康成功态，避免误导用户以为实时链路已就绪。
                return .neutral
            case .disconnected, .failed, .terminated:
                return .warning
            }
        } else if case .failed = sessionStore.webSocketStatus {
            return .warning
        } else if case .terminated = sessionStore.webSocketStatus {
            return .warning
        }
        return .neutral
    }

    // 连接状态以图标呈现，避免在工具栏里塞中文文字。
    private var connectionBadgeSymbol: String? {
        guard let session = sessionStore.selectedSession else {
            return nil
        }
        if case .failed = sessionStore.webSocketStatus {
            return "exclamationmark.triangle.fill"
        }
        if case .terminated = sessionStore.webSocketStatus {
            return "lock.trianglebadge.exclamationmark"
        }
        guard session.isRunning else {
            // closed/history 是普通完成态，不在顶部常驻提示；异常和运行态才需要占用视觉注意力。
            return nil
        }
        switch sessionStore.webSocketStatus {
        case .connected:
            return "dot.radiowaves.left.and.right"
        case .connecting:
            return "dot.radiowaves.left.and.right"
        case .disconnected:
            return "wifi.slash"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .terminated:
            return "lock.trianglebadge.exclamationmark"
        }
    }

    private var connectionBadgeColor: Color {
        let tokens = themeStore.tokens(for: colorScheme)
        switch connectionBadgeKind {
        case .success:
            return tokens.success
        case .warning:
            return tokens.warning
        case .neutral:
            return .secondary
        }
    }

    private func applyResponsiveColumnVisibility(for layout: WorkbenchLayout) {
        guard sessionStore.selectedSessionID != nil else {
            if columnVisibility == .detailOnly || layout.prefersDetailOnly {
                // 没有会话被选中时，窄 split 要回到项目/会话列表；否则会停在一个没有返回路径的详情列。
                columnVisibility = .all
            }
            return
        }
        guard layout.prefersDetailOnly else {
            return
        }
        columnVisibility = .detailOnly
    }

    private var compactSessionDetailBinding: Binding<Bool> {
        Binding(get: {
            sessionStore.selectedSessionID != nil
        }, set: { isPresented in
            guard !isPresented, sessionStore.selectedSessionID != nil else {
                return
            }
            sessionStore.returnToSessionList()
        })
    }
}

private struct NotificationRouteTaskID: Equatable {
    let route: SessionNotificationRoute?
    let hasCompletedInitialBootstrap: Bool
}

private enum AppTab: String, CaseIterable, Identifiable {
    case sessions
    case workspace
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions:
            return "会话"
        case .workspace:
            return "工作区"
        case .settings:
            return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .sessions:
            return "bubble.left.and.bubble.right"
        case .workspace:
            return "folder"
        case .settings:
            return "gearshape"
        }
    }

    @ViewBuilder
    var label: some View {
        Label(title, systemImage: systemImage)
    }
}

enum WorkbenchPageLayout {
    static let maxContentWidth: CGFloat = 820
    static let regularPadding: CGFloat = 24
    static let compactPadding: CGFloat = 20
    static let compactBottomPadding: CGFloat = 132
}

struct WorkbenchPageHeader: View {
    @EnvironmentObject private var themeStore: ThemeStore
    let title: String
    let subtitle: String
    let tokens: ThemeTokens

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(themeStore.uiFont(.title2, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
            Text(subtitle)
                .font(themeStore.uiFont(.callout))
                .foregroundStyle(tokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LegacyWorkspaceRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isPresentingOpenWorkspace = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return GeometryReader { proxy in
            let usesSplitLayout = horizontalSizeClass == .regular && proxy.size.width >= 720
            let hasProjects = !sessionStore.sidebarProjects.isEmpty

            if usesSplitLayout && !hasProjects && !sessionStore.isLoading {
                workspaceEmptyLanding()
            } else if usesSplitLayout {
                let sidebarWidth = min(max(proxy.size.width * 0.44, 440), 640)
                HStack(spacing: 0) {
                    workspaceGrid(usesSplitLayout: true, availableWidth: sidebarWidth)
                        .frame(width: sidebarWidth)
                    Rectangle()
                        .fill(tokens.border.opacity(0.72))
                        .frame(width: 1)
                    WorkspaceDetailView(project: selectedProject)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(tokens.background)
            } else {
                NavigationStack {
                    workspaceGrid(usesSplitLayout: false, availableWidth: proxy.size.width)
                        .navigationTitle("工作区")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .themedWorkbenchNavigationChrome(tokens: tokens, colorScheme: themeStore.resolvedColorScheme(for: colorScheme))
            }
        }
        .background(tokens.background.ignoresSafeArea())
        .sheet(isPresented: $isPresentingOpenWorkspace) {
            OpenWorkspaceSheet()
        }
    }

    private func workspaceEmptyLanding() -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                WorkbenchPageHeader(
                    title: "工作区",
                    subtitle: workspaceSummary,
                    tokens: tokens
                )

                WorkspaceEmptyStateCard(
                    systemImage: "folder.badge.plus",
                    title: "打开第一个工作区",
                    detail: "工作区用来管理开发目录；加入会话后，会话页只显示你常用的项目。",
                    actionTitle: "打开目录",
                    actionSystemImage: "folder.badge.plus"
                ) {
                    isPresentingOpenWorkspace = true
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 32)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(tokens.background.ignoresSafeArea())
    }

    private var selectedProject: AgentProject? {
        sessionStore.selectedProject ?? sessionStore.sidebarProjects.first
    }

    private func workspaceGrid(usesSplitLayout: Bool, availableWidth: CGFloat) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let projects = sessionStore.sidebarProjects
        let columns = workspaceColumns(usesSplitLayout: usesSplitLayout, availableWidth: availableWidth)
        let cardHeight = workspaceCardHeight(usesSplitLayout: usesSplitLayout, availableWidth: availableWidth)
        let usesCompactCards = !usesSplitLayout

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                workspaceGridHeader(tokens: tokens, projects: projects, usesSplitLayout: usesSplitLayout)

                if projects.isEmpty && !sessionStore.isLoading {
                    WorkspaceEmptyStateCard(
                        systemImage: "folder.badge.plus",
                        title: "没有已打开的工作区",
                        detail: "打开项目后，这里会以文件夹卡片展示；会话页只显示你加入会话的项目。",
                        actionTitle: "打开目录",
                        actionSystemImage: "folder.badge.plus"
                    ) {
                        isPresentingOpenWorkspace = true
                    }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(projects) { project in
                            WorkspaceFolderCard(
                                project: project,
                                isSelected: project.id == selectedProject?.id,
                                isShownInSessions: sessionStore.isWorkspaceShownInSessions(project.id),
                                isUnavailable: sessionStore.isWorkspaceUnavailable(project.id),
                                sessionCount: sessionStore.sessions(forProjectID: project.id).count,
                                worktreeCount: managedWorktreeCount(for: project),
                                cardHeight: cardHeight,
                                usesCompactLayout: usesCompactCards,
                                onSelect: {
                                    Task { await sessionStore.selectProject(project) }
                                },
                                onToggleSessionVisibility: {
                                    sessionStore.toggleWorkspaceInSessions(project)
                                }
                            )
                        }
                    }

                    if sessionStore.sessionWorkspaceIDs != nil {
                        Button {
                            sessionStore.resetSessionWorkspaceSelection()
                        } label: {
                            Label("恢复全部显示", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(tokens.accent)
                        .accessibilityLabel("恢复会话页显示全部工作区")
                    }
                }
            }
            .padding(.horizontal, usesSplitLayout ? WorkbenchPageLayout.regularPadding : WorkbenchPageLayout.compactPadding)
            .padding(.top, usesSplitLayout ? WorkbenchPageLayout.regularPadding : WorkbenchPageLayout.compactPadding)
            .padding(.bottom, usesSplitLayout ? WorkbenchPageLayout.regularPadding : WorkbenchPageLayout.compactBottomPadding)
        }
        .background(tokens.background.ignoresSafeArea())
        .refreshable {
            await sessionStore.refreshAll(autoAttach: false)
        }
    }

    @ViewBuilder
    private func workspaceGridHeader(tokens: ThemeTokens, projects: [AgentProject], usesSplitLayout: Bool) -> some View {
        if usesSplitLayout {
            HStack(alignment: .top, spacing: 16) {
                WorkbenchPageHeader(
                    title: "工作区",
                    subtitle: workspaceSummary,
                    tokens: tokens
                )

                Spacer(minLength: 0)

                workspaceHeaderActions(tokens: tokens, projects: projects)
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                Text(workspaceSummary)
                    .font(themeStore.uiFont(.callout, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                workspaceHeaderActions(tokens: tokens, projects: projects)
            }
        }
    }

    @ViewBuilder
    private func workspaceHeaderActions(tokens: ThemeTokens, projects: [AgentProject]) -> some View {
        if sessionStore.isLoading {
            ProgressView()
                .controlSize(.small)
                .tint(tokens.secondaryText)
                .frame(width: 32, height: 32)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(tokens.elevatedSurface.opacity(0.58), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(tokens.border.opacity(0.5), lineWidth: 1)
                }
                .accessibilityLabel("正在刷新工作区")
        } else if !projects.isEmpty {
            HStack(spacing: 2) {
                workspaceHeaderButton(tokens: tokens, systemImage: "arrow.clockwise", accessibilityLabel: "刷新工作区") {
                    Task { await sessionStore.refreshAll(autoAttach: false) }
                }

                workspaceHeaderButton(tokens: tokens, systemImage: "folder.badge.plus", accessibilityLabel: "打开目录") {
                    isPresentingOpenWorkspace = true
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(tokens.elevatedSurface.opacity(0.58), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(tokens.border.opacity(0.5), lineWidth: 1)
            }
        }
    }

    private func workspaceHeaderButton(
        tokens: ThemeTokens,
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.secondaryText)
        .accessibilityLabel(accessibilityLabel)
    }

    private func workspaceColumns(usesSplitLayout: Bool, availableWidth: CGFloat) -> [GridItem] {
        if usesSplitLayout {
            guard availableWidth >= 520 else {
                return [GridItem(.flexible(minimum: 0), spacing: 14)]
            }
            return [
                GridItem(.flexible(minimum: 0), spacing: 14),
                GridItem(.flexible(minimum: 0), spacing: 14)
            ]
        }
        return [GridItem(.flexible(minimum: 0), spacing: 14)]
    }

    private func workspaceCardHeight(usesSplitLayout: Bool, availableWidth: CGFloat) -> CGFloat {
        if usesSplitLayout {
            return availableWidth >= 520 ? 238 : 224
        }
        return 142
    }

    private var workspaceSummary: String {
        let total = sessionStore.sidebarProjects.count
        let shown = sessionStore.sessionWorkspaceSelectionCount
        guard total > 0 else {
            return "还没有打开工作区"
        }
        if sessionStore.sessionWorkspaceIDs == nil {
            return "\(total) 个工作区，会话页显示全部"
        }
        return "\(total) 个工作区，会话页显示 \(shown) 个"
    }

    private func managedWorktreeCount(for project: AgentProject) -> Int {
        let rootProjectID = sessionStore.rootProjectID(forProjectID: project.id)
        return sessionStore.managedWorktrees(rootProjectID: rootProjectID).count
    }
}

private struct WorkspaceEmptyStateCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let systemImage: String
    let title: String
    let detail: String
    var actionTitle: String?
    var actionSystemImage: String?
    var action: (() -> Void)?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 30, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.secondaryText)
                .frame(width: 54, height: 54)
                .background(tokens.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(spacing: 6) {
                Text(title)
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(themeStore.uiFont(.callout))
                    .foregroundStyle(tokens.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    if let actionSystemImage {
                        Label(actionTitle, systemImage: actionSystemImage)
                    } else {
                        Text(actionTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 2)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 236)
        .background(tokens.elevatedSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tokens.border, lineWidth: 1)
        }
    }
}

private struct WorkspaceFolderCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let project: AgentProject
    let isSelected: Bool
    let isShownInSessions: Bool
    let isUnavailable: Bool
    let sessionCount: Int
    let worktreeCount: Int
    let cardHeight: CGFloat
    let usesCompactLayout: Bool
    let onSelect: () -> Void
    let onToggleSessionVisibility: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let statusTone = isUnavailable ? tokens.warning : tokens.success
        let cardFill = isSelected ? tokens.accent.opacity(0.13) : tokens.elevatedSurface.opacity(0.78)
        let cardStroke = isSelected ? tokens.accent : tokens.border.opacity(0.86)

        if usesCompactLayout {
            compactBody(tokens: tokens, statusTone: statusTone, cardFill: cardFill, cardStroke: cardStroke)
        } else {
            regularBody(tokens: tokens, statusTone: statusTone, cardFill: cardFill, cardStroke: cardStroke)
        }
    }

    private func regularBody(tokens: ThemeTokens, statusTone: Color, cardFill: Color, cardStroke: Color) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        WorkspaceFolderGlyph(
                            isSelected: isSelected,
                            isUnavailable: isUnavailable,
                            size: .large
                        )

                        Spacer(minLength: 8)
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: isSelected ? 20 : 16, weight: .semibold))
                            .foregroundStyle(isSelected ? tokens.accent : tokens.tertiaryText)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.name)
                            .font(themeStore.uiFont(.headline, weight: .semibold))
                            .foregroundStyle(tokens.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.86)
                        Text(project.path)
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                WorkspaceMetricChip(value: "\(sessionCount)", title: "会话", systemImage: "bubble.left.and.text.bubble.right")
                WorkspaceMetricChip(value: "\(worktreeCount)", title: "Worktree", systemImage: "arrow.triangle.branch")
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusTone)
                        .frame(width: 8, height: 8)
                    Text(isUnavailable ? "异常" : "正常")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.secondaryText)
                }
                .accessibilityLabel(isUnavailable ? "不可用" : "可访问")
            }

            Spacer(minLength: 0)
            sessionVisibilityButton
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: cardHeight, maxHeight: cardHeight, alignment: .topLeading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(cardStroke, lineWidth: isSelected ? 2 : 1)
        }
    }

    private func compactBody(tokens: ThemeTokens, statusTone: Color, cardFill: Color, cardStroke: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 12) {
                    WorkspaceFolderGlyph(
                        isSelected: isSelected,
                        isUnavailable: isUnavailable,
                        size: .compact
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(project.name)
                                .font(themeStore.uiFont(.headline, weight: .semibold))
                                .foregroundStyle(tokens.primaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)

                            Spacer(minLength: 8)

                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: isSelected ? 18 : 15, weight: .semibold))
                                .foregroundStyle(isSelected ? tokens.accent : tokens.tertiaryText)
                        }

                        Text(project.path)
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                WorkspaceMetricChip(value: "\(sessionCount)", title: "会话", systemImage: "bubble.left.and.text.bubble.right")
                WorkspaceMetricChip(value: "\(worktreeCount)", title: "Worktree", systemImage: "arrow.triangle.branch")

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusTone)
                        .frame(width: 7, height: 7)
                    Text(isUnavailable ? "异常" : "正常")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                }
                .accessibilityLabel(isUnavailable ? "不可用" : "可访问")

                Spacer(minLength: 0)

                sessionVisibilityCompactButton
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: cardHeight, maxHeight: cardHeight, alignment: .topLeading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tokens.accent)
                    .frame(width: 4)
                    .padding(.vertical, 12)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(cardStroke, lineWidth: isSelected ? 2 : 1)
        }
    }

    @ViewBuilder
    private var sessionVisibilityButton: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        if isShownInSessions {
            Button(action: onToggleSessionVisibility) {
                Label("会话中", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
            .font(themeStore.uiFont(.callout, weight: .semibold))
            .foregroundStyle(tokens.accent)
            .background(tokens.accent.opacity(0.14), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(tokens.accent.opacity(0.26), lineWidth: 1)
            }
            .controlSize(.small)
        } else {
            Button(action: onToggleSessionVisibility) {
                Label("加入会话", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
            .font(themeStore.uiFont(.callout, weight: .semibold))
            .foregroundStyle(tokens.accent)
            .background(tokens.surface.opacity(0.72), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(tokens.border.opacity(0.72), lineWidth: 1)
            }
            .controlSize(.small)
        }
    }

    private var sessionVisibilityCompactButton: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return Button(action: onToggleSessionVisibility) {
            Label(isShownInSessions ? "会话中" : "加入", systemImage: isShownInSessions ? "checkmark.circle.fill" : "plus.circle")
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.accent)
        .background((isShownInSessions ? tokens.accent : tokens.surface).opacity(isShownInSessions ? 0.14 : 0.72), in: Capsule())
        .overlay {
            Capsule()
                .stroke(isShownInSessions ? tokens.accent.opacity(0.26) : tokens.border.opacity(0.72), lineWidth: 1)
        }
        .accessibilityLabel(isShownInSessions ? "从会话页移除" : "加入会话页")
    }
}

private struct WorkspaceMetricChip: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let value: String
    let title: String
    let systemImage: String

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(value)
                .monospacedDigit()
        }
        .font(themeStore.uiFont(.caption, weight: .semibold))
        .foregroundStyle(tokens.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tokens.surface.opacity(0.72), in: Capsule())
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .accessibilityLabel("\(title) \(value)")
    }
}

private struct WorkspaceFolderGlyph: View {
    enum Size {
        case large
        case compact
        case header

        var width: CGFloat {
            switch self {
            case .large:
                return 52
            case .compact:
                return 44
            case .header:
                return 40
            }
        }

        var height: CGFloat {
            switch self {
            case .large:
                return 52
            case .compact:
                return 44
            case .header:
                return 40
            }
        }
    }

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let isSelected: Bool
    let isUnavailable: Bool
    let size: Size

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let tone = isUnavailable ? tokens.warning : (isSelected ? tokens.accent : tokens.secondaryText)

        Image(systemName: isSelected ? "folder.fill" : "folder")
            .font(themeStore.uiFont(size: size == .large ? 28 : 21, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tone)
            .frame(width: size.width, height: size.height)
            .background(tone.opacity(isSelected ? 0.16 : 0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tone.opacity(isSelected ? 0.42 : 0.18), lineWidth: 1)
            }
        .accessibilityHidden(true)
    }
}

private struct WorkspaceDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    let project: AgentProject?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if let project {
                workspaceContent(project: project, tokens: tokens)
            } else {
                WorkspaceEmptyStateCard(
                    systemImage: "folder",
                    title: "选择一个工作区",
                    detail: "选择后可查看会话、Worktree 和权限状态。"
                )
                .frame(maxWidth: 420)
                .padding(32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle(project?.name ?? "工作区")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func workspaceContent(project: AgentProject, tokens: ThemeTokens) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                workspaceHeader(project: project, tokens: tokens)
                workspaceStats(project: project, tokens: tokens)

                VStack(spacing: 12) {
                    WorkspaceDetailActionRow(
                        systemImage: "terminal",
                        title: "会话",
                        value: sessionSummary(for: project),
                        detail: "会话仍在“会话”工作区里创建和继续运行。",
                        tone: tokens.accent,
                        showsChevron: false
                    )
                    WorkspaceDetailActionRow(
                        systemImage: "square.stack.3d.up",
                        title: "Git Worktree",
                        value: worktreeSummary(for: project),
                        detail: "在项目行菜单里管理这个工作区的 Worktree。",
                        tone: tokens.secondaryText,
                        showsChevron: false
                    )
                    WorkspaceDetailActionRow(
                        systemImage: "checkmark.shield",
                        title: "权限状态",
                        value: sessionStore.isWorkspaceUnavailable(project.id) ? "需要重试" : "可访问",
                        detail: sessionStore.isWorkspaceUnavailable(project.id) ? "这个工作区可能已被移动、删除或不在授权范围内。" : "当前工作区在已授权范围内，可继续用于会话。",
                        tone: sessionStore.isWorkspaceUnavailable(project.id) ? tokens.warning : tokens.success,
                        showsChevron: false
                    )
                }
            }
            .padding(.horizontal, 34)
            .padding(.top, 28)
            .padding(.bottom, 34)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .background(tokens.background.ignoresSafeArea())
    }

    private func workspaceHeader(project: AgentProject, tokens: ThemeTokens) -> some View {
        HStack(alignment: .top, spacing: 14) {
            WorkspaceFolderGlyph(
                isSelected: true,
                isUnavailable: sessionStore.isWorkspaceUnavailable(project.id),
                size: .header
            )

            VStack(alignment: .leading, spacing: 7) {
                Text(project.name)
                    .font(themeStore.uiFont(.title2, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(2)
                Text(project.path)
                    .font(themeStore.uiFont(.callout))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Image(systemName: "link")
                Text("路径已绑定")
            }
            .font(themeStore.uiFont(.caption, weight: .semibold))
            .foregroundStyle(tokens.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(tokens.elevatedSurface.opacity(0.8), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(tokens.border, lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func workspaceStats(project: AgentProject, tokens: ThemeTokens) -> some View {
        let columns = [
            GridItem(.flexible(minimum: 150), spacing: 12),
            GridItem(.flexible(minimum: 150), spacing: 12)
        ]

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            WorkspaceStatTile(
                title: "会话",
                value: "\(sessionStore.sessions(forProjectID: project.id).count)",
                systemImage: "bubble.left.and.text.bubble.right",
                tone: tokens.accent
            )
            WorkspaceStatTile(
                title: "Worktree",
                value: "\(managedWorktreeCount(for: project))",
                systemImage: "arrow.triangle.branch",
                tone: tokens.secondaryText
            )
            WorkspaceStatTile(
                title: "状态",
                value: sessionStore.isWorkspaceUnavailable(project.id) ? "异常" : "正常",
                systemImage: sessionStore.isWorkspaceUnavailable(project.id) ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                tone: sessionStore.isWorkspaceUnavailable(project.id) ? tokens.warning : tokens.success
            )
            WorkspaceStatTile(
                title: "最近更新",
                value: lastActivityText(for: project),
                systemImage: "clock",
                tone: tokens.secondaryText
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionSummary(for project: AgentProject) -> String {
        let count = sessionStore.sessions(forProjectID: project.id).count
        return count == 0 ? "暂无历史" : "\(count) 个"
    }

    private func worktreeSummary(for project: AgentProject) -> String {
        let count = managedWorktreeCount(for: project)
        return count == 0 ? "暂无" : "\(count) 个"
    }

    private func managedWorktreeCount(for project: AgentProject) -> Int {
        let rootProjectID = sessionStore.rootProjectID(forProjectID: project.id)
        return sessionStore.managedWorktrees(rootProjectID: rootProjectID).count
    }

    private func lastActivityText(for project: AgentProject) -> String {
        let sessions = sessionStore.sessions(forProjectID: project.id)
        guard let date = sessions.compactMap({ $0.updatedAt ?? $0.createdAt }).max() else {
            return "暂无"
        }
        return Self.minuteTimeFormatter.string(from: date)
    }

    private static let minuteTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct WorkspaceStatTile: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String
    let systemImage: String
    let tone: Color

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 16, weight: .semibold))
                .foregroundStyle(tone)
                .frame(width: 28, height: 28)
                .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(value)
                .font(themeStore.uiFont(.headline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(title)
                .font(themeStore.uiFont(.caption, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .background(tokens.elevatedSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tokens.border, lineWidth: 1)
        }
    }
}

private struct WorkspaceDetailActionRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let systemImage: String
    let title: String
    let value: String
    let detail: String
    let tone: Color
    let showsChevron: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tone.opacity(0.12))
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tone)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(1)
                    Text(value)
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .foregroundStyle(tone)
                        .lineLimit(1)
                }
                Text(detail)
                    .font(themeStore.uiFont(.callout))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tokens.tertiaryText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(tokens.elevatedSurface.opacity(0.76), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tokens.border, lineWidth: 1)
        }
    }
}
