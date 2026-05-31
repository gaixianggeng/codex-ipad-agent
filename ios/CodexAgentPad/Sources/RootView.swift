import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false

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
        } content: {
            ConversationView()
                .navigationTitle(sessionStore.selectedSession?.title ?? sessionStore.selectedProject?.name ?? "会话")
                .toolbar {
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
                        Button {
                            Task { await sessionStore.refreshAll(autoAttach: false) }
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        Button {
                            showingSettings = true
                        } label: {
                            Label("设置", systemImage: "gearshape")
                        }
                    }
                }
        } detail: {
            LogPanelView()
                .navigationTitle("日志")
                .navigationBarTitleDisplayMode(.inline)
                // 终端只是辅助观察区，默认压到窄栏，把主空间留给对话。
                .navigationSplitViewColumnWidth(min: 160, ideal: 210, max: 260)
        }
        .navigationSplitViewStyle(.balanced)
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
