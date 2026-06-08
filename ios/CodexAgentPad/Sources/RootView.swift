import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false
    @State private var showingLogInspector = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if appStore.isConfigured {
                mainLayout
            } else {
                SettingsView(isInitialSetup: true)
                    .environment(\.themeSystemColorScheme, colorScheme)
            }
        }
        .task {
            await sessionStore.bootstrap()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(isInitialSetup: false)
                .environment(\.themeSystemColorScheme, colorScheme)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                return
            }
            Task {
                await sessionStore.resumeFromForeground()
            }
        }
        .onOpenURL { url in
            handlePairingURL(url)
        }
        .environment(\.themeSystemColorScheme, colorScheme)
        .preferredColorScheme(themeStore.preferredColorScheme)
        .tint(tokens.accent)
        .background(tokens.background.ignoresSafeArea())
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
    }

    private func compactLayout(layout: WorkbenchLayout) -> some View {
        NavigationStack {
            ProjectSidebarView(showsSessions: true)
                .navigationTitle("Codex")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("设置", systemImage: "gearshape")
                        }
                        .labelStyle(.iconOnly)
                        .keyboardShortcut(",", modifiers: .command)
                        .help("设置")
                        .accessibilityLabel("设置")
                    }
                }
                .navigationDestination(isPresented: compactSessionDetailBinding) {
                    workspaceDetail(
                        layout: layout,
                        showsSidebarToggle: false,
                        showsReturnButton: false
                    )
                }
        }
        .onChange(of: sessionStore.selectedSessionID) { _, sessionID in
            if sessionID == nil {
                showingLogInspector = false
            }
        }
    }

    private func splitLayout(layout: WorkbenchLayout) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectSidebarView(showsSessions: true)
                // 侧栏本身用 Section header 呈现“项目”，隐藏大标题可以让项目树首屏更紧凑。
                .toolbar(.hidden, for: .navigationBar)
                // 侧栏宽度跟随窗口缩放，iPad mini/浮窗不会把详情区挤到只剩一条窄缝。
                .navigationSplitViewColumnWidth(
                    min: layout.projectColumn.min,
                    ideal: layout.projectColumn.ideal,
                    max: layout.projectColumn.max
                )
        } detail: {
            workspaceDetail(
                layout: layout,
                showsSidebarToggle: true,
                showsReturnButton: true
            )
        }
        .navigationSplitViewStyle(.balanced)
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

    private func workspaceDetail(
        layout: WorkbenchLayout,
        showsSidebarToggle: Bool,
        showsReturnButton: Bool
    ) -> some View {
        WorkspaceView()
            .navigationTitle(sessionStore.selectedSession?.title ?? sessionStore.selectedProject?.name ?? "会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 12) {
                        AgentWorkbenchTitle(maxWidth: layout.titleMaxWidth)
                        refreshControl
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    // 仅在侧栏收起时，在主界面提供展开按钮；展开时由侧栏自带的开关负责收起，避免两个图标同时出现。
                    if showsSidebarToggle && columnVisibility == .detailOnly {
                        Button {
                            withAnimation {
                                columnVisibility = .all
                            }
                        } label: {
                            Label("显示项目栏", systemImage: "sidebar.left")
                        }
                        .help("显示项目栏")
                        .accessibilityLabel("显示项目栏")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if showsReturnButton && sessionStore.selectedSessionID != nil {
                        Button {
                            sessionStore.returnToSessionList()
                        } label: {
                            Label("回到项目", systemImage: "xmark.circle")
                        }
                        .help("回到项目")
                        .accessibilityLabel("回到项目")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let symbol = connectionBadgeSymbol {
                        Image(systemName: symbol)
                            .foregroundStyle(connectionBadgeColor)
                            .symbolRenderingMode(.hierarchical)
                            .accessibilityLabel(sessionStore.connectionBadgeTitle ?? "连接状态")
                    }
                    if sessionStore.selectedSessionID != nil {
                        Button {
                            showingLogInspector.toggle()
                        } label: {
                            Label(layout.usesAttachedInspector ? "日志" : "会话详情", systemImage: layout.usesAttachedInspector ? "terminal" : "sidebar.right")
                        }
                        .labelStyle(.iconOnly)
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .help(layout.usesAttachedInspector ? "切换日志" : "切换会话详情")
                        .accessibilityLabel(showingLogInspector ? "隐藏详情" : "显示详情")
                    }
                    Button {
                        showingSettings = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(",", modifiers: .command)
                    .help("设置")
                    .accessibilityLabel("设置")
                }
            }
            .sessionInspectorPresentation(isPresented: $showingLogInspector, layout: layout)
    }

    // 刷新挪到标题旁，与右侧的日志/设置图标分开，避免功能与视觉都挤在右上角。
    @ViewBuilder
    private var refreshControl: some View {
        if sessionStore.isLoading || sessionStore.isRefreshingSelectedSession {
            ProgressView()
                .controlSize(.small)
                .tint(.orange)
                .accessibilityLabel("正在刷新")
        } else {
            Button {
                Task { await sessionStore.refreshCurrentContext() }
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)
            .help(sessionStore.selectedSessionID == nil ? "刷新会话列表" : "刷新当前会话")
            .accessibilityLabel(sessionStore.selectedSessionID == nil ? "刷新会话列表" : "刷新当前会话")
        }
    }

    private var connectionBadgeKind: StatusPill.Kind {
        if sessionStore.selectedSession?.isRunning == true, sessionStore.webSocketStatus == .connected {
            return .success
        }
        if case .failed = sessionStore.webSocketStatus {
            return .warning
        }
        return .neutral
    }

    // 连接状态以图标呈现，避免在工具栏里塞中文文字。
    private var connectionBadgeSymbol: String? {
        guard let session = sessionStore.selectedSession else {
            return nil
        }
        guard session.isRunning else {
            if session.isAppServerHistory {
                return "clock"
            }
            return session.status == "closed" ? "checkmark.circle" : "circle.dashed"
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
        }
    }

    private var connectionBadgeColor: Color {
        switch connectionBadgeKind {
        case .success:
            return .green
        case .warning:
            return .orange
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
            if columnVisibility == .detailOnly {
                columnVisibility = .all
            }
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

    private func handlePairingURL(_ url: URL) {
        do {
            try appStore.preparePairingURL(url)
            showingSettings = appStore.isConfigured
        } catch {
            appStore.connectionStatus = .failed(error.localizedDescription)
            appStore.lastError = error.localizedDescription
        }
    }
}

private struct WorkbenchLayout: Equatable {
    struct ColumnWidth: Equatable {
        let min: CGFloat
        let ideal: CGFloat
        let max: CGFloat
    }

    let projectColumn: ColumnWidth
    let inspectorColumn: ColumnWidth
    let titleMaxWidth: CGFloat
    let usesCompactNavigation: Bool
    let prefersDetailOnly: Bool
    let usesAttachedInspector: Bool

    init(containerWidth: CGFloat, horizontalSizeClass: UserInterfaceSizeClass?) {
        let isCompactWidth = horizontalSizeClass == .compact || containerWidth < 760
        let isTightPadWidth = containerWidth < 980

        if isCompactWidth {
            projectColumn = ColumnWidth(min: 220, ideal: 260, max: 300)
            titleMaxWidth = 180
        } else if isTightPadWidth {
            projectColumn = ColumnWidth(min: 240, ideal: 280, max: 320)
            titleMaxWidth = 240
        } else {
            projectColumn = ColumnWidth(min: 280, ideal: 330, max: 380)
            titleMaxWidth = 340
        }

        inspectorColumn = containerWidth < 1280
            ? ColumnWidth(min: 280, ideal: 300, max: 320)
            : ColumnWidth(min: 300, ideal: 340, max: 380)

        // 三栏只在真正宽的横向空间里附着；窄窗口改用 sheet，保住会话阅读/输入区域。
        usesAttachedInspector = horizontalSizeClass != .compact && containerWidth >= 1180
        usesCompactNavigation = isCompactWidth
        prefersDetailOnly = isCompactWidth || containerWidth < 860
    }
}

private extension View {
    func sessionInspectorPresentation(isPresented: Binding<Bool>, layout: WorkbenchLayout) -> some View {
        modifier(SessionInspectorPresentation(isPresented: isPresented, layout: layout))
    }
}

private struct SessionInspectorPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let layout: WorkbenchLayout

    @ViewBuilder
    func body(content: Content) -> some View {
        if layout.usesAttachedInspector {
            content.inspector(isPresented: $isPresented) {
                SessionInspectorView()
                    .inspectorColumnWidth(
                        min: layout.inspectorColumn.min,
                        ideal: layout.inspectorColumn.ideal,
                        max: layout.inspectorColumn.max
                    )
            }
        } else {
            content.sheet(isPresented: $isPresented) {
                NavigationStack {
                    SessionInspectorView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("完成") {
                                    isPresented = false
                                }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

private struct AgentWorkbenchTitle: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let maxWidth: CGFloat

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(spacing: 2) {
            HStack(spacing: 6) {
                statusDot
                Text(primaryText)
                    .font(themeStore.codeFont(.subheadline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            Text(secondaryText)
                .font(themeStore.codeFont(.caption2))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .frame(maxWidth: maxWidth)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusDot: some View {
        if sessionStore.selectedForegroundActivity != nil {
            ProgressView()
                .controlSize(.small)
                .tint(.green)
        } else {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
        }
    }

    private var dotColor: Color {
        if sessionStore.selectedSession?.isRunning == true, sessionStore.webSocketStatus == .connected {
            return .green
        }
        if case .failed = sessionStore.webSocketStatus {
            return .orange
        }
        return .secondary.opacity(0.65)
    }

    private var primaryText: String {
        if let session = sessionStore.selectedSession {
            return session.project.isEmpty ? "Codex" : session.project
        }
        return sessionStore.selectedProject?.name ?? "Codex"
    }

    private var secondaryText: String {
        if let session = sessionStore.selectedSession {
            return session.title.isEmpty ? session.dir : session.title
        }
        return sessionStore.selectedProject?.path ?? "请选择项目"
    }
}

struct StatusPill: View {
    enum Kind {
        case success
        case warning
        case neutral
    }

    let text: String
    let kind: Kind
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Text(text)
            .font(themeStore.uiFont(size: 12, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.86)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background(tokens: tokens))
            .foregroundStyle(foreground(tokens: tokens))
            .clipShape(Capsule())
    }

    private func background(tokens: ThemeTokens) -> Color {
        switch kind {
        case .success:
            return tokens.success.opacity(0.16)
        case .warning:
            return tokens.warning.opacity(0.18)
        case .neutral:
            return tokens.elevatedSurface
        }
    }

    private func foreground(tokens: ThemeTokens) -> Color {
        switch kind {
        case .success:
            return tokens.success
        case .warning:
            return tokens.warning
        case .neutral:
            return tokens.secondaryText
        }
    }
}
