import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
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
        .environment(\.themeSystemColorScheme, colorScheme)
        .preferredColorScheme(themeStore.preferredColorScheme)
        .tint(tokens.accent)
        .background(tokens.background.ignoresSafeArea())
    }

    private var mainLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectSidebarView(showsSessions: true)
                // 侧栏本身用 Section header 呈现“项目”，隐藏大标题可以让项目树首屏更紧凑。
                .toolbar(.hidden, for: .navigationBar)
                // 项目和会话合并到同一个原生 sidebar 后，需要给会话标题和状态留足宽度。
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
        } detail: {
            WorkspaceView()
                .navigationTitle(sessionStore.selectedSession?.title ?? sessionStore.selectedProject?.name ?? "会话")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 12) {
                            AgentWorkbenchTitle()
                            refreshControl
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        // 仅在侧栏收起时，在主界面提供展开按钮；展开时由侧栏自带的开关负责收起，避免两个图标同时出现。
                        if columnVisibility == .detailOnly {
                            Button {
                                withAnimation {
                                    columnVisibility = .all
                                }
                            } label: {
                                Label("显示项目栏", systemImage: "sidebar.left")
                            }
                            .accessibilityLabel("显示项目栏")
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        if sessionStore.selectedSessionID != nil {
                            Button {
                                sessionStore.returnToSessionList()
                            } label: {
                                Label("回到项目", systemImage: "xmark.circle")
                            }
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
                                Label("日志", systemImage: "terminal")
                            }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel(showingLogInspector ? "隐藏日志" : "显示日志")
                        }
                        Button {
                            showingSettings = true
                        } label: {
                            Label("设置", systemImage: "gearshape")
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("设置")
                    }
                }
                .inspector(isPresented: $showingLogInspector) {
                    SessionInspectorView()
                        // Inspector 作为辅助诊断面板，不参与主 split 的空间分配。
                        .inspectorColumnWidth(min: 240, ideal: 300, max: 360)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: sessionStore.selectedSessionID) { _, sessionID in
            if sessionID == nil {
                showingLogInspector = false
            }
        }
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
}

private struct AgentWorkbenchTitle: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

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
        .frame(maxWidth: 360)
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
