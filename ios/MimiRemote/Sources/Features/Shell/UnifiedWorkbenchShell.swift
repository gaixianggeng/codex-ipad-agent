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

/// iPad 和 iPhone 共用同一套导航状态；iPad 展开为单侧栏，窄屏由系统自动折叠成 push 导航。
struct UnifiedWorkbenchShell: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    @Binding var showingInspector: Bool
    @State private var selection: AppDestination? = .sessions
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var presentedSheet: AppSheetDestination?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        GeometryReader { proxy in
            let layout = WorkbenchLayout(containerWidth: proxy.size.width, horizontalSizeClass: nil)

            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar(tokens: tokens)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 340)
            } detail: {
                detail(layout: layout, tokens: tokens)
            }
            .navigationSplitViewStyle(.balanced)
        }
        .background(tokens.background.ignoresSafeArea())
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .newSession:
                NewSessionSheet(
                    onCreated: { sessionID in
                        selection = .session(sessionID)
                    },
                    onOpenWorkspaces: {
                        selection = .workspaces
                    }
                )
            case .settings:
                SettingsView(isInitialSetup: false)
            }
        }
        .onAppear {
            if let sessionID = sessionStore.selectedSessionID {
                selection = .session(sessionID)
            }
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
            selection = .session(sessionID)
        }
    }

    private func sidebar(tokens: ThemeTokens) -> some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    sidebarDestinationRow(
                        destination: .sessions,
                        title: "会话",
                        systemImage: "bubble.left.and.bubble.right"
                    )
                    sidebarDestinationRow(
                        destination: .workspaces,
                        title: "工作区",
                        systemImage: "folder"
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

            Divider().overlay(tokens.border.opacity(0.7))

            VStack(spacing: 8) {
                Button {
                    // 设置是临时配置面板，不改变用户当前所在的会话或工作区。
                    presentedSheet = .settings
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "gearshape")
                            .frame(width: 22)
                        Text("设置")
                        Spacer()
                    }
                    .font(themeStore.uiFont(.callout, weight: .medium))
                    .foregroundStyle(presentedSheet == .settings ? tokens.primaryText : tokens.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(presentedSheet == .settings ? tokens.selectionFill : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    presentedSheet = .newSession
                } label: {
                    Label("新会话", systemImage: "plus")
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .foregroundStyle(tokens.primaryActionForeground)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .tint(tokens.primaryAction)
                .accessibilityLabel("新建会话")
            }
            .padding(14)
        }
        .background(tokens.sidebarBackground.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .principal) {
                // 标题放进系统顶栏，才能与 iPad 的侧栏收起按钮保持同一行。
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Mimi Remote")
                            .font(themeStore.uiFont(.headline, weight: .semibold))
                            .foregroundStyle(tokens.primaryText)
                        Text(connectionSubtitle)
                            .font(themeStore.uiFont(.caption2))
                            .foregroundStyle(tokens.tertiaryText)
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
        .task {
            await sessionStore.refreshSessionLibraryIndex()
        }
    }

    private func sidebarDestinationRow(
        destination: AppDestination,
        title: String,
        systemImage: String
    ) -> some View {
        NavigationLink(value: destination) {
            Label(title, systemImage: systemImage)
                .font(themeStore.uiFont(.body, weight: selection == destination ? .semibold : .medium))
                .padding(.vertical, 4)
        }
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func detail(layout: WorkbenchLayout, tokens: ThemeTokens) -> some View {
        switch selection ?? .sessions {
        case .sessions:
            NavigationStack {
                SessionListView(
                    onNewSession: { presentedSheet = .newSession },
                    onSelectSession: { session in
                        selection = .session(session.id)
                    }
                )
            }
        case .workspaces:
            WorkspaceRootView(
                onOpenInSessions: { project in
                    Task {
                        await sessionStore.selectProject(project)
                        selection = .sessions
                    }
                },
                onStartSession: { project, runtimeChoice in
                    Task {
                        await sessionStore.startNewSession(in: project, runtimeProvider: runtimeChoice.runtimeProvider)
                        if let sessionID = sessionStore.selectedSessionID {
                            selection = .session(sessionID)
                        }
                    }
                }
            )
        case .session:
            sessionDetail(layout: layout, tokens: tokens)
        }
    }

    private func sessionDetail(layout: WorkbenchLayout, tokens: ThemeTokens) -> some View {
        WorkspaceView {
            selection = .workspaces
        }
        .navigationTitle(sessionStore.selectedSession?.title ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(sessionStore.selectedSession?.title ?? "会话")
                        .font(themeStore.uiFont(.subheadline, weight: .semibold))
                        .lineLimit(1)
                    if let project = sessionStore.selectedSession?.project, !project.isEmpty {
                        Text(project)
                            .font(themeStore.uiFont(.caption2))
                            .foregroundStyle(tokens.tertiaryText)
                            .lineLimit(1)
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await sessionStore.refreshCurrentContext() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(sessionStore.isRefreshingSelectedSession || sessionStore.isLoading)
                .accessibilityLabel("刷新当前会话")

                Button {
                    showingInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .accessibilityLabel(showingInspector ? "隐藏详情" : "显示详情")
            }
        }
        .background(tokens.background.ignoresSafeArea())
        .sessionInspectorPresentation(isPresented: $showingInspector, layout: layout)
    }

    private var connectionSubtitle: String {
        sessionStore.webSocketStatus == .connected ? "Mac 已连接" : "远程开发工作台"
    }

    private func connectionTone(tokens: ThemeTokens) -> Color {
        switch sessionStore.webSocketStatus {
        case .connected: return tokens.success
        case .connecting: return tokens.warning
        case .failed: return .red
        case .disconnected: return tokens.tertiaryText
        }
    }
}

private struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("newSession.lastWorkspaceID") private var lastWorkspaceID = ""
    @AppStorage("newSession.lastRuntime") private var lastRuntimeID = WorkspaceSessionRuntimeChoice.codex.rawValue
    @State private var selectedWorkspaceID = ""
    @State private var isCreating = false

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
                    Form {
                        Section("工作区") {
                            Picker("项目", selection: $selectedWorkspaceID) {
                                ForEach(sessionStore.sidebarProjects) { project in
                                    VStack(alignment: .leading) {
                                        Text(project.name)
                                        Text(project.path)
                                    }
                                    .tag(project.id)
                                }
                            }
                            .pickerStyle(.inline)
                        }

                        Section("运行时") {
                            Picker("运行时", selection: $lastRuntimeID) {
                                ForEach(WorkspaceSessionRuntimeChoice.available(claudeChannelAvailable: sessionStore.hasClaudeRuntimeChannel)) { choice in
                                    Label(choice == .codex ? "Codex" : "Claude Code", systemImage: choice.systemImage)
                                        .tag(choice.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }
            }
            .navigationTitle("新会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                if !sessionStore.sidebarProjects.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await createSession() }
                        } label: {
                            if isCreating {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("创建")
                            }
                        }
                        .disabled(isCreating || selectedProject == nil)
                        .tint(tokens.primaryAction)
                    }
                }
            }
        }
        .onAppear {
            let projects = sessionStore.sidebarProjects
            if projects.contains(where: { $0.id == lastWorkspaceID }) {
                selectedWorkspaceID = lastWorkspaceID
            } else if let selected = sessionStore.selectedProject,
                      projects.contains(where: { $0.id == selected.id }) {
                selectedWorkspaceID = selected.id
            } else {
                selectedWorkspaceID = projects.first?.id ?? ""
            }
            if !sessionStore.hasClaudeRuntimeChannel {
                lastRuntimeID = WorkspaceSessionRuntimeChoice.codex.rawValue
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var selectedProject: AgentProject? {
        sessionStore.sidebarProjects.first { $0.id == selectedWorkspaceID }
    }

    private func createSession() async {
        guard let project = selectedProject else { return }
        isCreating = true
        defer { isCreating = false }
        let choice = WorkspaceSessionRuntimeChoice(rawValue: lastRuntimeID) ?? .codex
        lastWorkspaceID = project.id
        await sessionStore.startNewSession(in: project, runtimeProvider: choice.runtimeProvider)
        guard let sessionID = sessionStore.selectedSessionID else { return }
        dismiss()
        onCreated(sessionID)
    }
}
