import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false
    @State private var showingLogInspector = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        Group {
            if appStore.isConfigured {
                mainLayout
            } else {
                SettingsView(isInitialSetup: true)
            }
        }
        .task {
            await sessionStore.bootstrap()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(isInitialSetup: false)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                return
            }
            Task {
                await sessionStore.resumeFromForeground()
            }
        }
    }

    private var mainLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectSidebarView(showsSessions: false)
                .navigationTitle("Codex")
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } content: {
            SessionListView()
                .navigationTitle(sessionStore.selectedProject?.name ?? "会话")
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
                                Label("返回会话", systemImage: "chevron.left")
                            }
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
            if session.isCodexHistory {
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

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                statusDot
                Text(primaryText)
                    .font(.subheadline.monospaced().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            Text(secondaryText)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
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

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.86)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
    }

    private var background: Color {
        switch kind {
        case .success:
            return Color.green.opacity(0.16)
        case .warning:
            return Color.orange.opacity(0.18)
        case .neutral:
            return Color.secondary.opacity(0.12)
        }
    }

    private var foreground: Color {
        switch kind {
        case .success:
            return .green
        case .warning:
            return .orange
        case .neutral:
            return .secondary
        }
    }
}
