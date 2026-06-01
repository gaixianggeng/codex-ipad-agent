import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false
    @State private var showingLogInspector = false

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
        NavigationSplitView {
            ProjectSidebarView()
                .navigationTitle("Codex")
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
        } detail: {
            ConversationView()
                .navigationTitle(sessionStore.selectedSession?.title ?? sessionStore.selectedProject?.name ?? "会话")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(workbenchBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        AgentWorkbenchTitle()
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
                        if let badgeTitle = sessionStore.connectionBadgeTitle {
                            StatusPill(text: badgeTitle, kind: connectionBadgeKind)
                        }
                        if sessionStore.selectedSessionID != nil {
                            Button {
                                showingLogInspector.toggle()
                            } label: {
                                Label("日志", systemImage: "sidebar.right")
                            }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel(showingLogInspector ? "隐藏日志" : "显示日志")
                        }
                        if sessionStore.isLoading || sessionStore.isRefreshingSelectedSession {
                            ToolbarIconFrame {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.orange)
                            }
                            .accessibilityLabel("正在刷新")
                        } else {
                            Button {
                                Task { await sessionStore.refreshCurrentContext() }
                            } label: {
                                ToolbarIconFrame {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.orange)
                                }
                            }
                            .accessibilityLabel(sessionStore.selectedSessionID == nil ? "刷新会话列表" : "刷新当前会话")
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
                    LogPanelView()
                        // 日志作为辅助 inspector，不参与主 split 的空间分配。
                        .inspectorColumnWidth(min: 220, ideal: 260, max: 320)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: sessionStore.selectedSessionID) { _, sessionID in
            if sessionID == nil {
                showingLogInspector = false
            }
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

    private var workbenchBackground: Color {
        Color(red: 0.10, green: 0.13, blue: 0.18)
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

private struct ToolbarIconFrame<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(width: 34, height: 30)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
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
