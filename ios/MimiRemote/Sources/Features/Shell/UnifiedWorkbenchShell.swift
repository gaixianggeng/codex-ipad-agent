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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentedSheet = .newSession
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(tokens.primaryAction)
                .accessibilityLabel("新建会话")
                .accessibilityIdentifier("sidebar.newSession")
            }
            // 固定间距会阻止系统把两个操作合并进同一个玻璃容器，保持为独立圆钮。
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // 设置是临时配置面板，不改变用户当前所在的会话或工作区。
                    presentedSheet = .settings
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .foregroundStyle(tokens.secondaryText)
                .accessibilityLabel("打开设置")
                .accessibilityIdentifier("sidebar.settings")
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
                },
                onOpenSession: { session in
                    Task {
                        // 最近会话属于当前工作区索引，先恢复会话上下文，再切换详情路由。
                        await sessionStore.selectSession(session)
                        selection = .session(session.id)
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
                Button {
                    Task { await sessionStore.refreshCurrentContext() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .foregroundStyle(tokens.secondaryText)
                .disabled(sessionStore.isRefreshingSelectedSession || sessionStore.isLoading)
                .accessibilityLabel("刷新当前会话")
            }
            // 与主页的圆形操作保持同一节奏，同时让系统不要把刷新和详情合并成一个玻璃胶囊。
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .foregroundStyle(showingInspector ? tokens.primaryAction : tokens.secondaryText)
                .accessibilityLabel(showingInspector ? "隐藏详情" : "显示详情")
            }
        }
        .background(tokens.background.ignoresSafeArea())
        .themedWorkbenchNavigationChrome(tokens: tokens, colorScheme: themeStore.resolvedColorScheme(for: colorScheme))
        .sessionInspectorPresentation(isPresented: $showingInspector, layout: layout)
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
        let fiveHour = window(.fiveHour)
        let sevenDay = window(.sevenDay)

        return ZStack {
            usageRing(
                progress: sevenDay?.remainingProgress,
                diameter: metrics.diameter,
                lineWidth: metrics.outerLineWidth,
                tint: tint(for: .sevenDay),
                tokens: tokens
            )
            usageRing(
                progress: fiveHour?.remainingProgress,
                diameter: metrics.innerDiameter,
                lineWidth: metrics.innerLineWidth,
                tint: tint(for: .fiveHour),
                tokens: tokens
            )

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
                    Text(display.hasLiveData ? "5h 和 7d 账号窗口" : "尚未取得账号用量")
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
                usageWindowRow(kind: .fiveHour, tokens: tokens)
                Divider().overlay(tokens.border.opacity(0.72))
                usageWindowRow(kind: .sevenDay, tokens: tokens)
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

    private func usageWindowRow(kind: CodexUsageWindowKind, tokens: ThemeTokens) -> some View {
        let item = window(kind)
        let progress = item?.remainingProgress ?? 0
        let tint = tint(for: kind)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .stroke(tint, lineWidth: 2.5)
                    .frame(width: 12, height: 12)
                Text(kind.label)
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .monospacedDigit()
                Text(kind.title)
                    .font(themeStore.uiFont(.caption, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)

                Spacer(minLength: 8)

                Text(item?.remainingText ?? "等待刷新")
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(item?.remainingProgress == nil ? tokens.secondaryText : tint)
                    .monospacedDigit()
            }

            ProgressView(value: progress)
                .tint(tint)
                .opacity(item?.remainingProgress == nil ? 0.3 : 1)

            Text(item?.resetText ?? "暂无重置时间")
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.label) Codex 剩余用量")
        .accessibilityValue("\(item?.remainingText ?? "等待刷新")，\(item?.resetText ?? "暂无重置时间")")
    }

    private func refreshUsage() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await onRefresh()
    }

    private func window(_ kind: CodexUsageWindowKind) -> CodexUsageWindowDisplay? {
        display.windows.first { $0.kind == kind }
    }

    private var hasUsageProgress: Bool {
        display.windows.contains { $0.remainingProgress != nil }
    }

    private func tint(for kind: CodexUsageWindowKind) -> Color {
        switch kind {
        case .fiveHour:
            return .cyan
        case .sevenDay:
            return .pink
        }
    }

    private var accessibilityValue: String {
        let fiveHour = window(.fiveHour)?.remainingText ?? "等待刷新"
        let sevenDay = window(.sevenDay)?.remainingText ?? "等待刷新"
        return "5 小时\(fiveHour)，7 天\(sevenDay)"
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
    @AppStorage("newSession.lastWorkspaceID") private var lastWorkspaceID = ""
    @AppStorage("newSession.lastRuntime") private var lastRuntimeID = WorkspaceSessionRuntimeChoice.codex.rawValue
    @State private var selectedWorkspaceID = ""
    @State private var isCreating = false
    @State private var didLeaveSheetForCreation = false

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
        .onChange(of: sessionStore.selectedSessionID) { _, sessionID in
            guard isCreating,
                  let sessionID,
                  sessionID.hasPrefix("local:") else { return }
            leaveSheetForCreatedSession(sessionID)
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
        leaveSheetForCreatedSession(sessionID)
    }

    private func leaveSheetForCreatedSession(_ sessionID: SessionID) {
        guard !didLeaveSheetForCreation else { return }
        didLeaveSheetForCreation = true
        dismiss()
        onCreated(sessionID)
    }
}
