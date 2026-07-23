import SwiftUI

enum AppDestination: Hashable {
    case sessions
    case workspaces
    case session(SessionID)
}

private enum AppSheetDestination: String, Identifiable {
    case newSession
    case settings

    var id: String { rawValue }
}

enum CompactWorkbenchTab: Hashable {
    case sessions
    case workspaces
    case settings

    var title: String {
        switch self {
        case .sessions: return L10n.text("ui.session")
        case .workspaces: return L10n.text("ui.workspace")
        case .settings: return L10n.text("ui.settings")
        }
    }

    var systemImage: String {
        switch self {
        case .sessions: return "bubble.left.and.bubble.right"
        case .workspaces: return "folder"
        case .settings: return "gearshape"
        }
    }
}

enum WorkbenchNavigationEffect: Equatable {
    case returnToSessionList
    case selectSession(SessionID)
}

enum WorkbenchNavigationEvent: Equatable {
    case open(AppDestination, source: WorkbenchRootPage?)
    case synchronize(WorkbenchRestorationRoute)
    case selectedSessionChanged(SessionID?)
    case compactPathChanged(tab: CompactWorkbenchTab, path: [AppDestination])
    case compactTabChanged(CompactWorkbenchTab)
    case sessionSelectionFinished(SessionID)
}

/// 工作台导航的纯状态机。所有入口先在副本上归并，再一次性写回 SwiftUI，避免多个
/// `onChange` 在同一帧互相改写 selection、route 和 NavigationStack path。
struct WorkbenchNavigationState: Equatable {
    private(set) var route: WorkbenchRestorationRoute
    private(set) var selection: AppDestination?
    private(set) var compactSessionPath: [AppDestination]
    private(set) var compactWorkspacePath: [AppDestination]
    private(set) var compactSelectedTab: CompactWorkbenchTab
    private(set) var pendingSessionSelectionID: SessionID?

    init(route: WorkbenchRestorationRoute = .sessions) {
        self.route = route
        selection = Self.destination(for: route)
        compactSessionPath = []
        compactWorkspacePath = []
        pendingSessionSelectionID = nil

        switch route {
        case .sessions:
            compactSelectedTab = .sessions
        case .workspaces:
            compactSelectedTab = .workspaces
        case .session(let id, let source):
            let destination = AppDestination.session(id)
            switch source {
            case .sessions:
                compactSelectedTab = .sessions
                compactSessionPath = [destination]
            case .workspaces:
                compactSelectedTab = .workspaces
                compactWorkspacePath = [destination]
            }
        }
    }

    @discardableResult
    mutating func reduce(
        _ event: WorkbenchNavigationEvent,
        usesCompactNavigation: Bool,
        selectedSessionID: SessionID?
    ) -> WorkbenchNavigationEffect? {
        switch event {
        case .open(let destination, let requestedSource):
            return open(
                destination,
                requestedSource: requestedSource,
                usesCompactNavigation: usesCompactNavigation,
                selectedSessionID: selectedSessionID
            )

        case .synchronize(let restoredRoute):
            let preservedPendingSessionID = restoredRoute.detailSessionID == pendingSessionSelectionID
                ? pendingSessionSelectionID
                : nil
            route = restoredRoute
            selection = Self.destination(for: restoredRoute)
            pendingSessionSelectionID = preservedPendingSessionID
            guard usesCompactNavigation else { return nil }
            restoreCompactPath(for: restoredRoute)
            return nil

        case .selectedSessionChanged(let sessionID):
            pendingSessionSelectionID = nil
            guard let sessionID else {
                guard route.detailSessionID != nil else { return nil }
                applyRoot(route.rootPage, usesCompactNavigation: usesCompactNavigation)
                return nil
            }
            applySession(
                sessionID,
                source: usesCompactNavigation ? activeRootPage : route.rootPage,
                usesCompactNavigation: usesCompactNavigation,
                replacesCompactPath: false
            )
            return nil

        case .compactPathChanged(let tab, let path):
            guard tab != .settings else { return nil }
            compactSelectedTab = tab
            switch tab {
            case .sessions:
                compactSessionPath = path
            case .workspaces:
                compactWorkspacePath = path
            case .settings:
                break
            }

            let destination = path.last ?? Self.rootDestination(for: tab)
            selection = destination
            switch destination {
            case .sessions:
                route = .sessions
                pendingSessionSelectionID = nil
            case .workspaces:
                route = .workspaces
                pendingSessionSelectionID = nil
            case .session(let sessionID):
                route = .session(id: sessionID, source: Self.rootPage(for: tab))
            }
            return effectForUserNavigation(to: destination, selectedSessionID: selectedSessionID)

        case .compactTabChanged(let tab):
            compactSelectedTab = tab
            guard tab != .settings else {
                // 设置是全局配置，切入时保留当前会话/工作区上下文。
                return nil
            }
            let path = tab == .sessions ? compactSessionPath : compactWorkspacePath
            let destination = path.last ?? Self.rootDestination(for: tab)
            selection = destination
            switch destination {
            case .sessions:
                route = .sessions
                pendingSessionSelectionID = nil
            case .workspaces:
                route = .workspaces
                pendingSessionSelectionID = nil
            case .session(let sessionID):
                route = .session(id: sessionID, source: Self.rootPage(for: tab))
            }
            return effectForUserNavigation(to: destination, selectedSessionID: selectedSessionID)

        case .sessionSelectionFinished(let sessionID):
            if pendingSessionSelectionID == sessionID {
                pendingSessionSelectionID = nil
            }
            return nil
        }
    }

    private mutating func open(
        _ destination: AppDestination,
        requestedSource: WorkbenchRootPage?,
        usesCompactNavigation: Bool,
        selectedSessionID: SessionID?
    ) -> WorkbenchNavigationEffect? {
        switch destination {
        case .sessions:
            applyRoot(.sessions, usesCompactNavigation: usesCompactNavigation)
        case .workspaces:
            applyRoot(.workspaces, usesCompactNavigation: usesCompactNavigation)
        case .session(let sessionID):
            applySession(
                sessionID,
                source: requestedSource ?? (usesCompactNavigation ? activeRootPage : route.rootPage),
                usesCompactNavigation: usesCompactNavigation,
                replacesCompactPath: false
            )
        }
        return effectForUserNavigation(to: destination, selectedSessionID: selectedSessionID)
    }

    private mutating func applyRoot(
        _ page: WorkbenchRootPage,
        usesCompactNavigation: Bool
    ) {
        pendingSessionSelectionID = nil
        switch page {
        case .sessions:
            route = .sessions
            selection = .sessions
            guard usesCompactNavigation else { return }
            compactSelectedTab = .sessions
            compactSessionPath = []
        case .workspaces:
            route = .workspaces
            selection = .workspaces
            guard usesCompactNavigation else { return }
            compactSelectedTab = .workspaces
            compactWorkspacePath = []
        }
    }

    private mutating func applySession(
        _ sessionID: SessionID,
        source: WorkbenchRootPage,
        usesCompactNavigation: Bool,
        replacesCompactPath: Bool
    ) {
        let destination = AppDestination.session(sessionID)
        route = .session(id: sessionID, source: source)
        selection = destination
        guard usesCompactNavigation else { return }

        switch source {
        case .sessions:
            compactSelectedTab = .sessions
            compactSessionPath = replacesCompactPath
                ? [destination]
                : Self.sessionPath(afterOpening: destination, currentPath: compactSessionPath)
        case .workspaces:
            compactSelectedTab = .workspaces
            compactWorkspacePath = replacesCompactPath
                ? [destination]
                : Self.sessionPath(afterOpening: destination, currentPath: compactWorkspacePath)
        }
    }

    private mutating func restoreCompactPath(for restoredRoute: WorkbenchRestorationRoute) {
        switch restoredRoute {
        case .sessions:
            compactSelectedTab = .sessions
            compactSessionPath = []
        case .workspaces:
            compactSelectedTab = .workspaces
            compactWorkspacePath = []
        case .session(let sessionID, let source):
            applySession(
                sessionID,
                source: source,
                usesCompactNavigation: true,
                replacesCompactPath: true
            )
        }
    }

    private mutating func effectForUserNavigation(
        to destination: AppDestination,
        selectedSessionID: SessionID?
    ) -> WorkbenchNavigationEffect? {
        switch destination {
        case .sessions, .workspaces:
            return selectedSessionID == nil ? nil : .returnToSessionList
        case .session(let sessionID):
            guard selectedSessionID != sessionID,
                  pendingSessionSelectionID != sessionID else { return nil }
            // selectSession 包含网络恢复，可能跨帧；记录在途 ID，阻止同一个 UI 事件链重复启动。
            pendingSessionSelectionID = sessionID
            return .selectSession(sessionID)
        }
    }

    private var activeRootPage: WorkbenchRootPage {
        switch compactSelectedTab {
        case .sessions:
            return .sessions
        case .workspaces:
            return .workspaces
        case .settings:
            return route.rootPage
        }
    }

    private static func destination(for route: WorkbenchRestorationRoute) -> AppDestination {
        switch route {
        case .sessions:
            return .sessions
        case .workspaces:
            return .workspaces
        case .session(let id, _):
            return .session(id)
        }
    }

    private static func rootDestination(for tab: CompactWorkbenchTab) -> AppDestination {
        tab == .workspaces ? .workspaces : .sessions
    }

    private static func rootPage(for tab: CompactWorkbenchTab) -> WorkbenchRootPage {
        tab == .workspaces ? .workspaces : .sessions
    }

    private static func sessionPath(
        afterOpening destination: AppDestination,
        currentPath: [AppDestination]
    ) -> [AppDestination] {
        guard currentPath.last != destination else { return currentPath }

        var updatedPath = currentPath
        if let currentDestination = updatedPath.last,
           case .session = currentDestination {
            // local:* 占位切到真实 ID 时替换当前详情，不能再 push 一层。
            updatedPath[updatedPath.index(before: updatedPath.endIndex)] = destination
        } else {
            updatedPath.append(destination)
        }
        return updatedPath
    }
}

/// iPad 和 iPhone 共用同一套路由；宽屏使用侧栏，窄屏使用真正的 push 导航。
/// 不能只依赖 NavigationSplitView 自动折叠：折叠后的详情列没有返回栈，也就没有系统左缘返回手势。
struct UnifiedWorkbenchShell: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Binding var showingInspector: Bool
    @Binding var restorationRoute: WorkbenchRestorationRoute
    @State private var navigationState = WorkbenchNavigationState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var presentedSheet: AppSheetDestination?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        GeometryReader { proxy in
            let layout = WorkbenchLayout(
                containerWidth: proxy.size.width,
                horizontalSizeClass: horizontalSizeClass
            )

            Group {
                if layout.usesCompactNavigation {
                    compactLayout(
                        layout: layout,
                        tokens: tokens
                    )
                } else {
                    splitLayout(
                        layout: layout,
                        tokens: tokens,
                        bottomSafeAreaInset: proxy.safeAreaInsets.bottom
                    )
                }
            }
            .sheet(item: $presentedSheet) { sheet in
                switch sheet {
                case .newSession:
                    NewSessionSheet(
                        onCreated: { sessionID in
                            open(.session(sessionID), layout: layout)
                        },
                        onOpenWorkspaces: {
                            open(.workspaces, layout: layout)
                        }
                    )
                case .settings:
                    SettingsView(isInitialSetup: false)
                }
            }
            .onAppear {
                synchronizeNavigation(for: layout)
            }
            .onChange(of: layout.usesCompactNavigation) { _, usesCompactNavigation in
                guard usesCompactNavigation else { return }
                synchronizeNavigation(for: layout)
            }
            .onChange(of: sessionStore.selectedSessionID) { _, sessionID in
                handleSelectedSessionChange(sessionID, layout: layout)
            }
            .onChange(of: restorationRoute) { _, route in
                guard navigationState.route != route else { return }
                applyNavigation(.synchronize(route), layout: layout)
            }
        }
        .background(tokens.background.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            if appStore.requiresRePairing {
                credentialsInvalidBanner(tokens: tokens)
            } else if sessionStore.isNetworkUnavailable {
                networkUnavailableBanner(tokens: tokens)
            }
        }
    }

    private func compactLayout(
        layout: WorkbenchLayout,
        tokens: ThemeTokens
    ) -> some View {
        TabView(selection: compactTabBinding(layout: layout)) {
            NavigationStack(path: compactPathBinding(for: .sessions, layout: layout)) {
                sessionList(layout: layout)
                    .navigationDestination(for: AppDestination.self) { destination in
                        compactDestination(destination, layout: layout, tokens: tokens)
                    }
            }
            .tabItem {
                Label(CompactWorkbenchTab.sessions.title, systemImage: CompactWorkbenchTab.sessions.systemImage)
            }
            .tag(CompactWorkbenchTab.sessions)

            NavigationStack(path: compactPathBinding(for: .workspaces, layout: layout)) {
                workspaces(layout: layout)
                    .navigationDestination(for: AppDestination.self) { destination in
                        compactDestination(destination, layout: layout, tokens: tokens)
                    }
            }
            .tabItem {
                Label(CompactWorkbenchTab.workspaces.title, systemImage: CompactWorkbenchTab.workspaces.systemImage)
            }
            .tag(CompactWorkbenchTab.workspaces)

            NavigationStack {
                SettingsView(
                    isInitialSetup: false,
                    showsDoneButton: false,
                    embedsNavigationStack: false
                )
            }
            .tabItem {
                Label(CompactWorkbenchTab.settings.title, systemImage: CompactWorkbenchTab.settings.systemImage)
            }
            .tag(CompactWorkbenchTab.settings)
        }
        .themedWorkbenchNavigationChrome(
            tokens: tokens,
            colorScheme: themeStore.resolvedColorScheme(for: colorScheme)
        )
    }

    private func splitLayout(
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        bottomSafeAreaInset: CGFloat
    ) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar(tokens: tokens, layout: layout, bottomSafeAreaInset: bottomSafeAreaInset)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 340)
        } detail: {
            detail(layout: layout, tokens: tokens)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func credentialsInvalidBanner(tokens: ThemeTokens) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tokens.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("ui.access_code_has_expired"))
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(L10n.text("ui.automatic_retries_stopped_existing_sessions_remain_please_rescan"))
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
            }

            Spacer(minLength: 8)

            Button(L10n.text("ui.re_pair")) {
                presentedSheet = .settings
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("connection.repairPairing")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tokens.elevatedSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: 1)
        }
    }

    private func networkUnavailableBanner(tokens: ThemeTokens) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tokens.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("ui.network_is_unavailable"))
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(L10n.text("ui.synchronization_and_reconnection_have_been_paused_it_will"))
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tokens.elevatedSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: 1)
        }
        .accessibilityIdentifier("connection.networkUnavailable")
    }

    private func sidebar(
        tokens: ThemeTokens,
        layout: WorkbenchLayout,
        bottomSafeAreaInset: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding(layout: layout)) {
                Section {
                    sidebarDestinationRow(
                        destination: .sessions,
                        title: L10n.text("ui.session"),
                        systemImage: "bubble.left.and.bubble.right",
                        tokens: tokens,
                        layout: layout
                    )
                    sidebarDestinationRow(
                        destination: .workspaces,
                        title: L10n.text("ui.workspace"),
                        systemImage: "folder",
                        tokens: tokens,
                        layout: layout
                    )
                }

                if !sessionStore.activeSessions.isEmpty {
                    Section(L10n.text("ui.in_progress")) {
                        ForEach(sessionStore.activeSessions) { session in
                            sidebarSessionLink(session)
                        }
                    }
                }

                Section(sessionStore.activeSessions.isEmpty ? L10n.text("ui.recently") : L10n.text("ui.recent_history")) {
                    if sessionStore.recentHistorySessions.isEmpty {
                        Text(sessionStore.activeSessions.isEmpty ? L10n.text("ui.no_recent_conversations_yet") : L10n.text("ui.no_history_sessions_yet"))
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.tertiaryText)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(sessionStore.recentHistorySessions) { session in
                            sidebarSessionLink(session)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 38)
            // 覆盖式侧栏可能只按 List 的理想内容高度提案；显式占用剩余空间后，
            // 列表自身滚动，底部全局操作不会跟着短列表上浮。
            .frame(maxHeight: .infinity)

            // 设置属于整个工作台而不是某个列表项，固定在侧栏底部可让顶部只保留品牌和当前内容。
            sidebarFooter(tokens: tokens, bottomSafeAreaInset: bottomSafeAreaInset)
        }
        // NavigationSplitView 在 iPad 竖屏以 overlay 展开侧栏时不会保证内容采用整列理想高度，
        // 根容器必须主动填满列高，Footer 才能稳定锚定到底部安全区。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(tokens.sidebarBackground.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .principal) {
                // 标题放进系统顶栏，才能与 iPad 的侧栏收起按钮保持同一行。
                HStack(spacing: 8) {
                    CodexUsageRingsControl(
                        display: sessionStore.accountCodexUsageWindowsDisplay,
                        onRefresh: {
                            await sessionStore.refreshCodexUsage()
                        }
                    )

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Mimi Remote")
                                .font(themeStore.uiFont(.headline, weight: .semibold))
                                .foregroundStyle(tokens.primaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                            Text(connectionSubtitle)
                                .font(themeStore.uiFont(.caption2))
                                .foregroundStyle(tokens.tertiaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }

                        Circle()
                            .fill(connectionTone(tokens: tokens))
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(L10n.format("ui.mimi_remote_connection_accessibility", connectionSubtitle))
                }
            }
        }
        .task {
            await sessionStore.refreshSessionLibraryIndex()
        }
    }

    private func sidebarSessionLink(_ session: AgentSession) -> some View {
        NavigationLink(value: AppDestination.session(session.id)) {
            SessionIndexRow(
                session: session,
                foregroundActivity: sessionStore.foregroundActivity(for: session.id),
                isSelected: session.id == sessionStore.selectedSessionID,
                isPinned: sessionStore.isSessionPinned(session.id),
                isArchived: sessionStore.isSessionArchived(session.id),
                reminder: sessionStore.sessionReminder(for: session.id),
                isObserving: sessionStore.isSessionObserving(session),
                style: .sidebar
            )
        }
        .sessionRowActions(session)
        .listRowInsets(.init(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func sidebarFooter(tokens: ThemeTokens, bottomSafeAreaInset: CGFloat) -> some View {
        WorkbenchSidebarFooter(
            tokens: tokens,
            bottomSafeAreaInset: bottomSafeAreaInset,
            onOpenSettings: {
                // 设置是全局配置，不改变当前会话或工作区选择。
                presentedSheet = .settings
            },
            onNewSession: {
                // 侧栏底部保留全局新建入口，和会话页右上角共用同一个创建流程。
                presentedSheet = .newSession
            }
        )
    }

    private func sidebarDestinationRow(
        destination: AppDestination,
        title: String,
        systemImage: String,
        tokens: ThemeTokens,
        layout: WorkbenchLayout
    ) -> some View {
        let isSelected = navigationState.selection == destination

        return WorkbenchSidebarDestinationButton(
            title: title,
            systemImage: systemImage,
            isSelected: isSelected,
            tokens: tokens,
            action: { open(destination, layout: layout) }
        )
    }

    @ViewBuilder
    private func compactDestination(
        _ destination: AppDestination,
        layout: WorkbenchLayout,
        tokens: ThemeTokens
    ) -> some View {
        switch destination {
        case .sessions:
            sessionList(layout: layout)
        case .workspaces:
            workspaces(layout: layout)
        case .session:
            sessionDetail(layout: layout, tokens: tokens)
        }
    }

    @ViewBuilder
    private func detail(layout: WorkbenchLayout, tokens: ThemeTokens) -> some View {
        switch navigationState.selection ?? .sessions {
        case .sessions:
            NavigationStack {
                sessionList(layout: layout)
            }
        case .workspaces:
            workspaces(layout: layout)
        case .session:
            sessionDetail(layout: layout, tokens: tokens)
        }
    }

    private func sessionList(layout: WorkbenchLayout) -> some View {
        SessionListView(
            onNewSession: { presentedSheet = .newSession },
            onSelectSession: { session in
                openSession(session, source: .sessions, layout: layout)
            }
        )
    }

    private func workspaces(layout: WorkbenchLayout) -> some View {
        WorkspaceRootView(
            onStartSession: { project, runtimeChoice in
                Task {
                    await sessionStore.startNewSession(in: project, runtimeProvider: runtimeChoice.runtimeProvider)
                }
            },
            onOpenSession: { session in
                // 选择会话和切换路由由同一个入口发起，避免 selectedSessionID 的回调再次 open。
                openSession(session, source: .workspaces, layout: layout)
            },
            // 紧凑布局的 destination 必须复用外层绑定 path 的 NavigationStack。
            embedsNavigationStack: WorkspaceRootView.shouldEmbedNavigationStack(
                usesCompactNavigation: layout.usesCompactNavigation
            )
        )
    }

    private func sessionDetail(layout: WorkbenchLayout, tokens: ThemeTokens) -> some View {
        WorkspaceView {
            open(.workspaces, layout: layout)
        }
        .navigationTitle(sessionStore.selectedSession?.title ?? L10n.text("ui.session"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(sessionStore.selectedSession?.title ?? L10n.text("ui.session"))
                        .font(themeStore.uiFont(.subheadline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(selectedSessionStatusColor(tokens: tokens))
                            .frame(width: 5, height: 5)

                        Text(sessionTitleSubtitle)
                            .font(themeStore.uiFont(.caption2, weight: .medium))
                            .foregroundStyle(tokens.tertiaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: layout.titleMaxWidth)
                .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .topBarTrailing) {
                workbenchToolbarIconButton(
                    systemImage: "arrow.clockwise",
                    accessibilityLabel: L10n.text("ui.refresh_current_session"),
                    tokens: tokens,
                    isDisabled: sessionStore.isRefreshingSelectedSession || sessionStore.isLoading
                ) {
                    Task { await sessionStore.refreshCurrentContext() }
                }
            }
            // iOS 26 会让相邻 toolbar item 共用一块 Liquid Glass 背景；
            // 固定间距把刷新与详情面板拆成两个独立动作，降低误触。
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                workbenchToolbarIconButton(
                    systemImage: "sidebar.right",
                    accessibilityLabel: showingInspector ? L10n.text("ui.hide_details") : L10n.text("ui.show_details"),
                    tokens: tokens,
                    isActive: showingInspector
                ) {
                    showingInspector.toggle()
                }
            }
        }
        .background(tokens.background.ignoresSafeArea())
        .toolbar(.hidden, for: .tabBar)
        .themedWorkbenchNavigationChrome(tokens: tokens, colorScheme: themeStore.resolvedColorScheme(for: colorScheme))
        .sessionInspectorPresentation(isPresented: $showingInspector, layout: layout)
    }

    private func selectionBinding(layout: WorkbenchLayout) -> Binding<AppDestination?> {
        Binding(
            get: { navigationState.selection },
            set: { destination in
                // List 可能在数据刷新时短暂写 nil；忽略这一过渡值，避免无意关闭详情。
                guard let destination else { return }
                let source: WorkbenchRootPage? = if case .session = destination { .sessions } else { nil }
                applyNavigation(.open(destination, source: source), layout: layout)
            }
        )
    }

    private func compactPathBinding(
        for tab: CompactWorkbenchTab,
        layout: WorkbenchLayout
    ) -> Binding<[AppDestination]> {
        Binding(
            get: {
                tab == .workspaces
                    ? navigationState.compactWorkspacePath
                    : navigationState.compactSessionPath
            },
            set: { path in
                applyNavigation(.compactPathChanged(tab: tab, path: path), layout: layout)
            }
        )
    }

    private func compactTabBinding(layout: WorkbenchLayout) -> Binding<CompactWorkbenchTab> {
        Binding(
            get: { navigationState.compactSelectedTab },
            set: { tab in
                applyNavigation(.compactTabChanged(tab), layout: layout)
            }
        )
    }

    private func open(
        _ destination: AppDestination,
        source: WorkbenchRootPage? = nil,
        layout: WorkbenchLayout
    ) {
        applyNavigation(.open(destination, source: source), layout: layout)
    }

    private func openSession(
        _ session: AgentSession,
        source: WorkbenchRootPage,
        layout: WorkbenchLayout
    ) {
        applyNavigation(
            .open(.session(session.id), source: source),
            layout: layout,
            preferredSession: session
        )
    }

    private func synchronizeNavigation(for layout: WorkbenchLayout) {
        applyNavigation(.synchronize(restorationRoute), layout: layout)
    }

    private func handleSelectedSessionChange(
        _ sessionID: SessionID?,
        layout: WorkbenchLayout
    ) {
        if sessionID == nil, presentedSheet == .newSession {
            // 新建流程会先清空旧 ID，再写入 local:*；中间态不能把详情先 pop 回根页面。
            return
        }
        applyNavigation(.selectedSessionChanged(sessionID), layout: layout)
    }

    private func applyNavigation(
        _ event: WorkbenchNavigationEvent,
        layout: WorkbenchLayout,
        preferredSession: AgentSession? = nil
    ) {
        var nextState = navigationState
        let effect = nextState.reduce(
            event,
            usesCompactNavigation: layout.usesCompactNavigation,
            selectedSessionID: sessionStore.selectedSessionID
        )

        // 一个事件只提交一个本地导航状态，避免 NavigationStack 在同一帧接收多次 path 写入。
        if nextState != navigationState {
            navigationState = nextState
        }
        if restorationRoute != nextState.route {
            restorationRoute = nextState.route
        }

        switch effect {
        case .returnToSessionList:
            sessionStore.returnToSessionList()
        case .selectSession(let sessionID):
            let session = preferredSession?.id == sessionID
                ? preferredSession
                : sessionStore.sessionLibrarySessions.first(where: { $0.id == sessionID })
            guard let session else {
                applyNavigation(.sessionSelectionFinished(sessionID), layout: layout)
                return
            }
            Task {
                await sessionStore.selectSession(session)
                applyNavigation(.sessionSelectionFinished(sessionID), layout: layout)
            }
        case nil:
            break
        }
    }

    /// 顶栏交给系统工具栏材质和命中区域处理；这里只表达图标与激活状态，避免自绘圆形再叠一层系统玻璃。
    private func workbenchToolbarIconButton(
        systemImage: String,
        accessibilityLabel: String,
        tokens: ThemeTokens,
        isActive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
        }
        .foregroundStyle(isActive ? tokens.primaryAction : tokens.secondaryText)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var sessionTitleSubtitle: String {
        guard let session = sessionStore.selectedSession else {
            return L10n.text("ui.session")
        }
        let project = session.project.trimmingCharacters(in: .whitespacesAndNewlines)
        return project.isEmpty ? session.displayStatus(foregroundActivity: sessionStore.selectedForegroundActivity).title : project
    }

    private func selectedSessionStatusColor(tokens: ThemeTokens) -> Color {
        guard let session = sessionStore.selectedSession else {
            return tokens.tertiaryText
        }
        switch session.displayStatus(foregroundActivity: sessionStore.selectedForegroundActivity).tone {
        case .active:
            return tokens.primaryAction
        case .warning:
            return tokens.warning
        case .danger:
            return .red
        case .complete:
            return tokens.success
        case .neutral:
            return tokens.tertiaryText
        }
    }

    private var connectionSubtitle: String {
        if appStore.requiresRePairing {
            return L10n.text("ui.need_to_re_pair")
        }
        if sessionStore.isNetworkUnavailable {
            return L10n.text("ui.the_network_is_unavailable_waiting_for_automatic_reconnection")
        }
        return sessionStore.webSocketStatus == .connected ? L10n.text("ui.mac_is_connected") : L10n.text("ui.remote_development_workbench")
    }

    private func connectionTone(tokens: ThemeTokens) -> Color {
        if sessionStore.isNetworkUnavailable, !appStore.requiresRePairing {
            return tokens.warning
        }
        switch sessionStore.webSocketStatus {
        case .connected: return tokens.success
        case .connecting: return tokens.warning
        case .failed: return .red
        case .terminated: return .red
        case .disconnected: return tokens.tertiaryText
        }
    }
}

/// 固定导航入口自绘选中态，避免 iOS 26 SidebarListStyle 自动套用过圆的胶囊背景。
struct WorkbenchSidebarDestinationButton: View {
    @EnvironmentObject private var themeStore: ThemeStore

    let title: String
    let systemImage: String
    let isSelected: Bool
    let tokens: ThemeTokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(themeStore.uiFont(size: 18, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(tokens.primaryAction)
                    .frame(width: 24)

                Text(title)
                    .font(themeStore.uiFont(.body, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(tokens.primaryText)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(
                isSelected ? tokens.selectionFill : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(tokens.primaryAction)
                        .frame(width: 3, height: 22)
                        .padding(.leading, 3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowInsets(.init(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? L10n.text("ui.selected") : L10n.text("ui.not_selected"))
    }
}

/// 全局配置放左侧，主创建动作放右侧；两端布局在侧栏高度变化时保持稳定。
struct WorkbenchSidebarFooter: View {
    @EnvironmentObject private var themeStore: ThemeStore

    let tokens: ThemeTokens
    let bottomSafeAreaInset: CGFloat
    let onOpenSettings: () -> Void
    let onNewSession: () -> Void

    init(
        tokens: ThemeTokens,
        bottomSafeAreaInset: CGFloat = 0,
        onOpenSettings: @escaping () -> Void,
        onNewSession: @escaping () -> Void
    ) {
        self.tokens = tokens
        self.bottomSafeAreaInset = bottomSafeAreaInset
        self.onOpenSettings = onOpenSettings
        self.onNewSession = onNewSession
    }

    var body: some View {
        // footer 下方还包含系统安全区；向下补偿其一半（最多 10pt），让控件在整块可见底栏中视觉居中，
        // 同时仍把完整触控区域留在安全区之上。
        let safeAreaVisualOffset = min(max(bottomSafeAreaInset, 0) / 2, 10)

        HStack {
            Button(action: onOpenSettings) {
                Label(L10n.text("ui.settings"), systemImage: "gearshape")
                    .font(themeStore.uiFont(.subheadline, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(tokens.secondaryText)
            .background(tokens.surface.opacity(0.72), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(tokens.border.opacity(0.6), lineWidth: 1)
            }
            .accessibilityLabel(L10n.text("ui.open_settings"))
            .accessibilityIdentifier("sidebar.settings")

            Spacer(minLength: 0)

            Button(action: onNewSession) {
                Image(systemName: "plus")
                    .font(themeStore.uiFont(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(tokens.primaryAction, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(tokens.primaryAction.opacity(0.72), lineWidth: 1)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(tokens.primaryActionForeground)
            .accessibilityLabel(L10n.text("ui.new_session_3da224c4"))
            .accessibilityIdentifier("sidebar.newSession")
        }
        .offset(y: safeAreaVisualOffset)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tokens.sidebarBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(tokens.border.opacity(0.55))
                .frame(height: 1)
        }
    }
}

/// 侧栏标题旁的账号剩余用量入口。图形尺寸跟随横向尺寸环境变化，
/// 因而 iPad mini 分屏和 iPhone 会自动使用更紧凑的版本。
private struct CodexUsageRingsControl: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let display: CodexUsageWindowsDisplay
    let onRefresh: () async -> Void

    @State private var showsDetails = false
    @State private var isRefreshing = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let metrics = CodexUsageRingMetrics(isCompact: horizontalSizeClass == .compact)

        Button {
            showsDetails.toggle()
        } label: {
            usageRings(metrics: metrics)
                .frame(width: metrics.hitSize, height: metrics.hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("ui.codex_remaining_usage"))
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("sidebar.codexUsageRings")
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            usageDetails(tokens: tokens)
                .presentationCompactAdaptation(.sheet)
                .presentationDetents([.height(300), .medium])
                .presentationDragIndicator(.visible)
        }
    }

    private func usageRings(metrics: CodexUsageRingMetrics) -> some View {
        CodexUsageRingsGraphic(display: display, metrics: metrics)
    }

    private func usageDetails(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("ui.codex_remaining_usage"))
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(display.windowSummaryText)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                }

                Spacer(minLength: 8)

                Button {
                    Task { await refreshUsage() }
                } label: {
                    Group {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.secondaryText)
                .background(tokens.surface.opacity(0.72), in: Circle())
                .overlay {
                    Circle()
                        .stroke(tokens.border.opacity(0.72), lineWidth: 1)
                }
                .disabled(isRefreshing)
                .accessibilityLabel(L10n.text("ui.refresh_codex_usage_c0f2c6f0"))
            }

            VStack(spacing: 14) {
                if display.windows.isEmpty {
                    Text(L10n.text("ui.after_refreshing_the_account_window_currently_returned_by"))
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(display.windows.enumerated()), id: \.element.id) { index, window in
                        if index > 0 {
                            Divider().overlay(tokens.border.opacity(0.72))
                        }
                        usageWindowRow(window: window, tokens: tokens)
                    }
                }
            }

            HStack(spacing: 7) {
                Image(systemName: display.hasLiveData ? "checkmark.seal" : "info.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text(display.creditText)
                    .font(themeStore.uiFont(.caption, weight: .medium))
                    .lineLimit(2)
            }
            .foregroundStyle(tokens.secondaryText)
        }
        .padding(16)
        .frame(width: horizontalSizeClass == .compact ? nil : 300)
        .frame(maxWidth: horizontalSizeClass == .compact ? .infinity : nil, alignment: .leading)
    }

    private func usageWindowRow(window: CodexUsageWindowDisplay, tokens: ThemeTokens) -> some View {
        let progress = window.remainingProgress ?? 0
        let tint = tint(for: window)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .stroke(tint, lineWidth: 2.5)
                    .frame(width: 12, height: 12)
                Text(window.label)
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .monospacedDigit()
                Text(window.title)
                    .font(themeStore.uiFont(.caption, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)

                Spacer(minLength: 8)

                Text(window.remainingText)
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(window.remainingProgress == nil ? tokens.secondaryText : tint)
                    .monospacedDigit()
            }

            ProgressView(value: progress)
                .tint(tint)
                .opacity(window.remainingProgress == nil ? 0.3 : 1)

            Text(window.resetText)
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("ui.value_remaining_usage", window.accessibilityName))
        .accessibilityValue(L10n.format("ui.usage_window_accessibility_value", window.remainingText, window.resetText))
    }

    private func refreshUsage() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await onRefresh()
    }

    private func tint(for window: CodexUsageWindowDisplay) -> Color {
        if window.durationMinutes != nil {
            return window.isDayScaleWindow ? .pink : .cyan
        }
        return window.kind == .secondary ? .pink : .cyan
    }

    private var accessibilityValue: String {
        guard !display.windows.isEmpty else {
            return L10n.text("ui.account_usage_has_not_been_obtained_yet")
        }
        return display.windows
            .map { "\($0.accessibilityName)\($0.remainingText)" }
            .joined(separator: L10n.text("ui.list_separator"))
    }
}

/// 首页和设置页共用同一套双圆环，避免同一份额度在不同入口出现相反或不一致的视觉语义。
struct CodexUsageRingsGraphic: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let display: CodexUsageWindowsDisplay
    let metrics: CodexUsageRingMetrics

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let windows = Array(display.windows.prefix(2))

        ZStack {
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                usageRing(
                    progress: window.remainingProgress,
                    diameter: windows.count == 1 || index == 1 ? metrics.diameter : metrics.innerDiameter,
                    lineWidth: windows.count == 1 || index == 1 ? metrics.outerLineWidth : metrics.innerLineWidth,
                    tint: tint(for: window),
                    tokens: tokens
                )
            }

            if !display.windows.contains(where: { $0.remainingProgress != nil }) {
                Text("?")
                    .font(.system(size: metrics.questionMarkSize, weight: .bold, design: .rounded))
                    .foregroundStyle(tokens.tertiaryText)
            }
        }
        .frame(width: metrics.diameter, height: metrics.diameter)
        .accessibilityHidden(true)
    }

    private func usageRing(
        progress: Double?,
        diameter: CGFloat,
        lineWidth: CGFloat,
        tint: Color,
        tokens: ThemeTokens
    ) -> some View {
        ZStack {
            Circle()
                .stroke(tokens.tertiaryText.opacity(0.18), lineWidth: lineWidth)

            if let progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: progress)
    }

    private func tint(for window: CodexUsageWindowDisplay) -> Color {
        if window.durationMinutes != nil {
            return window.isDayScaleWindow ? .pink : .cyan
        }
        return window.kind == .secondary ? .pink : .cyan
    }
}

struct CodexUsageRingMetrics {
    let diameter: CGFloat
    let innerDiameter: CGFloat
    let outerLineWidth: CGFloat
    let innerLineWidth: CGFloat
    let hitSize: CGFloat
    let questionMarkSize: CGFloat

    init(isCompact: Bool) {
        diameter = isCompact ? 30 : 34
        innerDiameter = isCompact ? 20 : 23
        outerLineWidth = isCompact ? 3.4 : 3.8
        innerLineWidth = isCompact ? 3 : 3.2
        // 图形在 iPhone 上收紧，但点击区始终保持 44pt，兼顾窄屏排版和触控可用性。
        hitSize = 44
        questionMarkSize = isCompact ? 7 : 8
    }
}

#if DEBUG
#Preview(L10n.text("ui.codex_usage_dual_loop_adaptive")) {
    let loaded = CodexUsageWindowsDisplay.make(
        rateLimit: RateLimitSummary(primaryUsedPercent: 62, secondaryUsedPercent: 38)
    )
    let pending = CodexUsageWindowsDisplay.make(rateLimit: nil)

    HStack(spacing: 24) {
        CodexUsageRingsControl(display: loaded, onRefresh: {})
            .environment(\.horizontalSizeClass, .regular)
        CodexUsageRingsControl(display: loaded, onRefresh: {})
            .environment(\.horizontalSizeClass, .compact)
        CodexUsageRingsControl(display: pending, onRefresh: {})
            .environment(\.horizontalSizeClass, .compact)
    }
    .environmentObject(ThemeStore())
    .padding(20)
}
#endif

private struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("newSession.lastWorkspaceID") private var lastWorkspaceID = ""
    @AppStorage("newSession.lastRuntime") private var lastRuntimeID = WorkspaceSessionRuntimeChoice.codex.rawValue
    @State private var selectedWorkspaceID = ""
    @State private var isCreating = false
    @State private var didLeaveSheetForCreation = false
    @State private var creationErrorMessage: String?

    let onCreated: (SessionID) -> Void
    let onOpenWorkspaces: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            Group {
                if sessionStore.sidebarProjects.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.text("ui.no_workspace_yet"), systemImage: "folder.badge.plus")
                    } description: {
                        Text(L10n.text("ui.first_open_a_project_directory_on_your_mac"))
                    } actions: {
                        Button(L10n.text("ui.go_to_work_area")) {
                            dismiss()
                            onOpenWorkspaces()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(tokens.primaryAction)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            workspaceSection(tokens: tokens)
                            runtimeSection(tokens: tokens)

                            if let creationErrorMessage {
                                Label(creationErrorMessage, systemImage: "exclamationmark.circle.fill")
                                    .font(themeStore.uiFont(.caption))
                                    .foregroundStyle(tokens.warning)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(tokens.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .accessibilityIdentifier("newSession.creationError")
                            }
                        }
                        .frame(maxWidth: 520)
                        .padding(.horizontal, horizontalSizeClass == .compact ? 20 : 24)
                        .padding(.top, 22)
                        .padding(.bottom, 32)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .background(tokens.background)
                }
            }
            .navigationTitle(L10n.text("ui.new_session"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { dismiss() }
                        .disabled(isCreating)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("newSession.cancel")
                }
                if !sessionStore.sidebarProjects.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await createSession() }
                        } label: {
                            if isCreating {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(L10n.text("ui.creating"))
                                }
                            } else {
                                Text(L10n.text("ui.create"))
                            }
                        }
                        .frame(minWidth: 48)
                        .buttonStyle(.glassProminent)
                        .disabled(isCreating || selectedProject == nil)
                        .tint(tokens.primaryAction)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("newSession.create")
                    }
                }
            }
        }
        .onAppear {
            synchronizeWorkspaceSelection()
            normalizeRuntimeSelection()
        }
        .onChange(of: sessionStore.sidebarProjects.map(\.id)) { _, _ in
            synchronizeWorkspaceSelection()
        }
        .onChange(of: sessionStore.hasClaudeRuntimeChannel) { _, _ in
            normalizeRuntimeSelection()
        }
        .onChange(of: sessionStore.selectedSessionID) { _, sessionID in
            guard isCreating,
                  let sessionID,
                  sessionID.hasPrefix("local:") else { return }
            leaveSheetForCreatedSession(sessionID)
        }
        // iPhone 默认用紧凑高度展示完整配置，减少大面积空白；iPad 继续交给系统 form 尺寸适配。
        .modifier(NewSessionPresentationModifier(isCompact: horizontalSizeClass == .compact))
        .interactiveDismissDisabled(isCreating)
    }

    private func workspaceSection(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: L10n.text("ui.workspace"),
                subtitle: L10n.text("ui.the_session_will_run_in_the_selected_directory"),
                tokens: tokens
            )

            if let project = selectedProject ?? sessionStore.sidebarProjects.first {
                Menu {
                    ForEach(sessionStore.sidebarProjects) { candidate in
                        Button {
                            // 工作区属于创建参数，选择时只更新 Sheet 本地状态，不提前切换全局会话上下文。
                            selectedWorkspaceID = candidate.id
                            creationErrorMessage = nil
                        } label: {
                            if candidate.id == selectedWorkspaceID {
                                Label(workspaceMenuTitle(for: candidate), systemImage: "checkmark")
                            } else {
                                Text(workspaceMenuTitle(for: candidate))
                            }
                        }
                    }
                } label: {
                    workspaceSummary(project, tokens: tokens)
                }
                .buttonStyle(.plain)
                .disabled(isCreating)
                .accessibilityLabel(L10n.text("ui.select_workspace"))
                .accessibilityValue(L10n.format("ui.workspace_selection_accessibility", project.name, compactWorkspacePath(project.path)))
                .accessibilityIdentifier("newSession.workspace")
            }
        }
    }

    private func runtimeSection(tokens: ThemeTokens) -> some View {
        let choices = WorkspaceSessionRuntimeChoice.available(
            claudeChannelAvailable: sessionStore.hasClaudeRuntimeChannel
        )

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: L10n.text("ui.runtime"),
                subtitle: L10n.text("ui.select_the_agent_responsible_for_performing_the_task"),
                tokens: tokens
            )

            if choices.count > 1 {
                Picker(L10n.text("ui.runtime"), selection: $lastRuntimeID) {
                    ForEach(choices) { choice in
                        Text(runtimeTitle(for: choice))
                            .tag(choice.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isCreating)
                .accessibilityIdentifier("newSession.runtime")
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "terminal.fill")
                        .font(themeStore.uiFont(size: 16, weight: .semibold))
                        .foregroundStyle(tokens.primaryAction)
                        .frame(width: 36, height: 36)
                        .background(tokens.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Codex")
                            .font(themeStore.uiFont(.body, weight: .semibold))
                            .foregroundStyle(tokens.primaryText)
                        Text(L10n.text("ui.the_only_runtime_currently_available"))
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.tertiaryText)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "checkmark.circle.fill")
                        .font(themeStore.uiFont(size: 20, weight: .semibold))
                        .foregroundStyle(tokens.primaryAction)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(tokens.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tokens.border.opacity(0.76), lineWidth: 1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("newSession.runtime")
            }

            Text(L10n.text("ui.cannot_be_switched_during_runtime_after_creation"))
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.tertiaryText)
        }
    }

    private func sectionHeader(title: String, subtitle: String, tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(themeStore.uiFont(.headline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
            Text(subtitle)
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.tertiaryText)
        }
    }

    private func workspaceSummary(_ project: AgentProject, tokens: ThemeTokens) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(themeStore.uiFont(size: 17, weight: .semibold))
                .foregroundStyle(tokens.primaryAction)
                .frame(width: 38, height: 38)
                .background(tokens.accentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(themeStore.uiFont(.body, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)

                Text(compactWorkspacePath(project.path))
                    .font(themeStore.codeFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.up.chevron.down")
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.tertiaryText)
                .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 70)
        .background(tokens.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tokens.border.opacity(0.76), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func runtimeTitle(for choice: WorkspaceSessionRuntimeChoice) -> String {
        choice == .codex ? "Codex" : "Claude Code"
    }

    private func compactWorkspacePath(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/"),
              components.count >= 2,
              components.first == "Users" else {
            return path
        }
        // 隐去本机用户名既能降低视觉噪音，也避免在远程屏幕共享时反复暴露完整绝对路径。
        let relativeComponents = components.dropFirst(2)
        return relativeComponents.isEmpty ? "~" : "~/" + relativeComponents.joined(separator: "/")
    }

    private func workspaceMenuTitle(for project: AgentProject) -> String {
        let hasDuplicateName = sessionStore.sidebarProjects.filter { $0.name == project.name }.count > 1
        guard hasDuplicateName else { return project.name }

        let components = project.path.split(separator: "/", omittingEmptySubsequences: true)
        let parentName = components.dropLast().last.map(String.init) ?? compactWorkspacePath(project.path)
        return "\(project.name) — \(parentName)"
    }

    private var selectedProject: AgentProject? {
        sessionStore.sidebarProjects.first { $0.id == selectedWorkspaceID }
    }

    private func synchronizeWorkspaceSelection() {
        let projects = sessionStore.sidebarProjects
        guard !projects.contains(where: { $0.id == selectedWorkspaceID }) else { return }

        if projects.contains(where: { $0.id == lastWorkspaceID }) {
            selectedWorkspaceID = lastWorkspaceID
        } else if let selected = sessionStore.selectedProject,
                  projects.contains(where: { $0.id == selected.id }) {
            selectedWorkspaceID = selected.id
        } else {
            selectedWorkspaceID = projects.first?.id ?? ""
        }
    }

    private func normalizeRuntimeSelection() {
        let choices = WorkspaceSessionRuntimeChoice.available(
            claudeChannelAvailable: sessionStore.hasClaudeRuntimeChannel
        )
        guard choices.contains(where: { $0.rawValue == lastRuntimeID }) else {
            lastRuntimeID = choices.first?.rawValue ?? WorkspaceSessionRuntimeChoice.codex.rawValue
            return
        }
    }

    private func createSession() async {
        guard let project = selectedProject else { return }
        isCreating = true
        creationErrorMessage = nil
        defer { isCreating = false }
        let choices = WorkspaceSessionRuntimeChoice.available(
            claudeChannelAvailable: sessionStore.hasClaudeRuntimeChannel
        )
        // 创建前再次按当前通道能力校验，避免 Sheet 打开期间通道状态变化造成错误路由。
        let choice = choices.first(where: { $0.rawValue == lastRuntimeID }) ?? .codex
        lastWorkspaceID = project.id
        await sessionStore.startNewSession(in: project, runtimeProvider: choice.runtimeProvider)
        guard let sessionID = sessionStore.selectedSessionID else {
            creationErrorMessage = sessionStore.errorMessage ?? L10n.text("ui.creation_failed_please_try_again_later")
            return
        }
        leaveSheetForCreatedSession(sessionID)
    }

    private func leaveSheetForCreatedSession(_ sessionID: SessionID) {
        guard !didLeaveSheetForCreation else { return }
        didLeaveSheetForCreation = true
        dismiss()
        onCreated(sessionID)
    }
}

private struct NewSessionPresentationModifier: ViewModifier {
    let isCompact: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isCompact {
            content
                .presentationDetents([.height(430), .large])
                .presentationDragIndicator(.visible)
        } else {
            content.presentationSizing(.form)
        }
    }
}
