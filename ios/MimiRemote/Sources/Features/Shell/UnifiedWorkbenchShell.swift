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

/// iPad 和 iPhone 共用同一套路由；宽屏使用侧栏，窄屏使用真正的 push 导航。
/// 不能只依赖 NavigationSplitView 自动折叠：折叠后的详情列没有返回栈，也就没有系统左缘返回手势。
struct UnifiedWorkbenchShell: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Binding var showingInspector: Bool
    @State private var selection: AppDestination? = .sessions
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var compactPath: [AppDestination] = []
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
                        tokens: tokens,
                        bottomSafeAreaInset: proxy.safeAreaInsets.bottom
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
            .onChange(of: selection) { _, destination in
                guard case .session(let sessionID) = destination,
                      sessionID != sessionStore.selectedSessionID,
                      let session = sessionStore.sessionLibrarySessions.first(where: { $0.id == sessionID })
                else { return }
                Task { await sessionStore.selectSession(session) }
            }
            .onChange(of: sessionStore.selectedSessionID) { _, sessionID in
                guard let sessionID else { return }
                open(.session(sessionID), layout: layout)
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
        tokens: ThemeTokens,
        bottomSafeAreaInset: CGFloat
    ) -> some View {
        NavigationStack(path: $compactPath) {
            sidebar(tokens: tokens, layout: layout, bottomSafeAreaInset: bottomSafeAreaInset)
                .navigationDestination(for: AppDestination.self) { destination in
                    compactDestination(destination, layout: layout, tokens: tokens)
                }
        }
        .themedWorkbenchNavigationChrome(
            tokens: tokens,
            colorScheme: themeStore.resolvedColorScheme(for: colorScheme)
        )
        .onChange(of: compactPath) { oldPath, newPath in
            handleCompactPathChange(from: oldPath, to: newPath)
        }
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
                Text("访问码已失效")
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text("已停止自动重试；现有会话仍保留，请重新扫描 Mac 上的配对二维码。")
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
            }

            Spacer(minLength: 8)

            Button("重新配对") {
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
                Text("网络不可用")
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text("已暂停同步和重连；网络恢复后会自动重新连接，现有会话和排队消息不会清空。")
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
            List(selection: $selection) {
                Section {
                    sidebarDestinationRow(
                        destination: .sessions,
                        title: "会话",
                        systemImage: "bubble.left.and.bubble.right",
                        tokens: tokens,
                        layout: layout
                    )
                    sidebarDestinationRow(
                        destination: .workspaces,
                        title: "工作区",
                        systemImage: "folder",
                        tokens: tokens,
                        layout: layout
                    )
                }

                Section("最近") {
                    if sessionStore.recentSessions.isEmpty {
                        Text("还没有最近会话")
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.tertiaryText)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(sessionStore.recentSessions) { session in
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
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 38)

            // 设置属于整个工作台而不是某个列表项，固定在侧栏底部可让顶部只保留品牌和当前内容。
            sidebarFooter(tokens: tokens, bottomSafeAreaInset: bottomSafeAreaInset)
        }
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
                    .accessibilityLabel("Mimi Remote，\(connectionSubtitle)")
                }
            }
        }
        .task {
            await sessionStore.refreshSessionLibraryIndex()
        }
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
        let isSelected = selection == destination

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
        switch selection ?? .sessions {
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
                open(.session(session.id), layout: layout)
            }
        )
    }

    private func workspaces(layout: WorkbenchLayout) -> some View {
        WorkspaceRootView(
            onOpenInSessions: { project in
                Task {
                    await sessionStore.selectProject(project)
                    open(.sessions, layout: layout)
                }
            },
            onStartSession: { project, runtimeChoice in
                Task {
                    await sessionStore.startNewSession(in: project, runtimeProvider: runtimeChoice.runtimeProvider)
                    if let sessionID = sessionStore.selectedSessionID {
                        open(.session(sessionID), layout: layout)
                    }
                }
            },
            onOpenSession: { session in
                Task {
                    // 最近会话属于当前工作区索引，先恢复会话上下文，再切换详情路由。
                    await sessionStore.selectSession(session)
                    open(.session(session.id), layout: layout)
                }
            }
        )
    }

    private func sessionDetail(layout: WorkbenchLayout, tokens: ThemeTokens) -> some View {
        WorkspaceView {
            open(.workspaces, layout: layout)
        }
        .navigationTitle(sessionStore.selectedSession?.title ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(sessionStore.selectedSession?.title ?? "会话")
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
                    accessibilityLabel: "刷新当前会话",
                    tokens: tokens,
                    isDisabled: sessionStore.isRefreshingSelectedSession || sessionStore.isLoading
                ) {
                    Task { await sessionStore.refreshCurrentContext() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                workbenchToolbarIconButton(
                    systemImage: "sidebar.right",
                    accessibilityLabel: showingInspector ? "隐藏详情" : "显示详情",
                    tokens: tokens,
                    isActive: showingInspector
                ) {
                    showingInspector.toggle()
                }
            }
        }
        .background(tokens.background.ignoresSafeArea())
        .themedWorkbenchNavigationChrome(tokens: tokens, colorScheme: themeStore.resolvedColorScheme(for: colorScheme))
        .sessionInspectorPresentation(isPresented: $showingInspector, layout: layout)
    }

    private func open(_ destination: AppDestination, layout: WorkbenchLayout) {
        selection = destination

        guard layout.usesCompactNavigation,
              compactPath.last != destination else {
            return
        }
        // 窄屏路由必须进入 NavigationStack，系统才会同时提供返回按钮和左缘交互式返回。
        compactPath.append(destination)
    }

    private func synchronizeNavigation(for layout: WorkbenchLayout) {
        let destination = sessionStore.selectedSessionID.map(AppDestination.session)
            ?? selection
            ?? .sessions
        selection = destination

        guard layout.usesCompactNavigation,
              compactPath.last != destination else {
            return
        }
        // 首次进入窄屏或从宽屏旋转过来时，以当前可见内容建立一层确定的返回栈。
        compactPath = [destination]
    }

    private func handleCompactPathChange(
        from oldPath: [AppDestination],
        to newPath: [AppDestination]
    ) {
        let destination = newPath.last ?? .sessions
        selection = destination

        if isSessionDestination(oldPath.last), !isSessionDestination(newPath.last) {
            // 返回列表后停止当前会话订阅，沿用原紧凑导航的资源释放语义。
            sessionStore.returnToSessionList()
        }
    }

    private func isSessionDestination(_ destination: AppDestination?) -> Bool {
        guard let destination else { return false }
        if case .session = destination {
            return true
        }
        return false
    }

    /// 工具栏使用单层圆形底，不再叠加系统 glass 的外圈；在浅色和深色主题下都和列表操作一致。
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
                .frame(width: 34, height: 34)
                .background(
                    isActive ? tokens.selectionFill : tokens.surface.opacity(0.72),
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .stroke(tokens.border.opacity(0.62), lineWidth: 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? tokens.primaryAction : tokens.secondaryText)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var sessionTitleSubtitle: String {
        guard let session = sessionStore.selectedSession else {
            return "会话"
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
            return "需要重新配对"
        }
        if sessionStore.isNetworkUnavailable {
            return "网络不可用，等待自动重连"
        }
        return sessionStore.webSocketStatus == .connected ? "Mac 已连接" : "远程开发工作台"
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
                    .foregroundStyle(isSelected ? tokens.primaryActionForeground : tokens.primaryAction)
                    .frame(width: 24)

                Text(title)
                    .font(themeStore.uiFont(.body, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? tokens.primaryActionForeground : tokens.primaryText)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(
                isSelected ? tokens.primaryAction : Color.clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowInsets(.init(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
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
                Label("设置", systemImage: "gearshape")
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
            .accessibilityLabel("打开设置")
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
            .accessibilityLabel("新建会话")
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
            usageRings(metrics: metrics, tokens: tokens)
                .frame(width: metrics.hitSize, height: metrics.hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Codex 剩余用量")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("sidebar.codexUsageRings")
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            usageDetails(tokens: tokens)
                .presentationCompactAdaptation(.sheet)
                .presentationDetents([.height(300), .medium])
                .presentationDragIndicator(.visible)
        }
    }

    private func usageRings(metrics: CodexUsageRingMetrics, tokens: ThemeTokens) -> some View {
        let windows = Array(display.windows.prefix(2))

        return ZStack {
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                usageRing(
                    progress: window.remainingProgress,
                    diameter: windows.count == 1 || index == 1 ? metrics.diameter : metrics.innerDiameter,
                    lineWidth: windows.count == 1 || index == 1 ? metrics.outerLineWidth : metrics.innerLineWidth,
                    tint: tint(for: window),
                    tokens: tokens
                )
            }

            if !hasUsageProgress {
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
        .animation(.snappy(duration: 0.25), value: progress)
    }

    private func usageDetails(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex 剩余用量")
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
                .accessibilityLabel("刷新 Codex 用量")
            }

            VStack(spacing: 14) {
                if display.windows.isEmpty {
                    Text("刷新后显示 Codex 当前返回的账号窗口")
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
        .accessibilityLabel("\(window.accessibilityName)剩余用量")
        .accessibilityValue("\(window.remainingText)，\(window.resetText)")
    }

    private func refreshUsage() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await onRefresh()
    }

    private var hasUsageProgress: Bool {
        display.windows.contains { $0.remainingProgress != nil }
    }

    private func tint(for window: CodexUsageWindowDisplay) -> Color {
        if window.durationMinutes != nil {
            return window.isDayScaleWindow ? .pink : .cyan
        }
        return window.kind == .secondary ? .pink : .cyan
    }

    private var accessibilityValue: String {
        guard !display.windows.isEmpty else {
            return "尚未取得账号用量"
        }
        return display.windows
            .map { "\($0.accessibilityName)\($0.remainingText)" }
            .joined(separator: "，")
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
#Preview("Codex 用量双环自适应") {
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
                        Label("还没有工作区", systemImage: "folder.badge.plus")
                    } description: {
                        Text("先打开一个 Mac 上的项目目录，再创建会话。")
                    } actions: {
                        Button("去工作区") {
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
            .navigationTitle("新会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
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
                                    Text("创建中")
                                }
                            } else {
                                Text("创建")
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
                title: "工作区",
                subtitle: "会话会在所选目录中运行",
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
                .accessibilityLabel("选择工作区")
                .accessibilityValue("\(project.name)，\(compactWorkspacePath(project.path))")
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
                title: "运行时",
                subtitle: "选择负责执行任务的 Agent",
                tokens: tokens
            )

            if choices.count > 1 {
                Picker("运行时", selection: $lastRuntimeID) {
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
                        Text("当前唯一可用运行时")
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

            Text("创建后运行时不能切换")
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
            creationErrorMessage = sessionStore.errorMessage ?? "创建失败，请稍后重试。"
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
