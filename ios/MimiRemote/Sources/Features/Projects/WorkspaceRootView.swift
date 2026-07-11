import SwiftUI

enum WorkspaceSessionRuntimeChoice: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var runtimeProvider: String? {
        switch self {
        case .codex:
            return nil
        case .claude:
            return "claude"
        }
    }

    var title: String {
        switch self {
        case .codex:
            return "新建 Codex 会话"
        case .claude:
            return "新建 Claude Code 会话"
        }
    }

    var systemImage: String {
        switch self {
        case .codex:
            return "plus.circle"
        case .claude:
            return "sparkles"
        }
    }

    static func available(claudeChannelAvailable: Bool) -> [Self] {
        claudeChannelAvailable ? [.codex, .claude] : [.codex]
    }
}

/// 工作区只维护本地浏览选择。只有用户明确进入会话或新建会话时，才交给 SessionStore 改变活动上下文。
struct WorkspaceRootView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let onOpenInSessions: (AgentProject) -> Void
    let onStartSession: (AgentProject, WorkspaceSessionRuntimeChoice) -> Void

    @State private var selectedWorkspaceID: String?
    @State private var catalogState: CatalogState = .idle
    @State private var isPresentingOpenWorkspace = false

    init(
        onOpenInSessions: @escaping (AgentProject) -> Void,
        onStartSession: @escaping (AgentProject, WorkspaceSessionRuntimeChoice) -> Void
    ) {
        self.onOpenInSessions = onOpenInSessions
        self.onStartSession = onStartSession
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            workspaceBrowser(tokens: tokens)
                .navigationTitle("工作区")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isPresentingOpenWorkspace = true
                        } label: {
                            Label("打开目录", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(tokens.primaryAction)
                    }
                }
        }
        .task {
            synchronizeSelection()
            if sessionStore.sidebarProjects.isEmpty && !sessionStore.isLoading {
                await refreshCatalog()
            } else if !sessionStore.sidebarProjects.isEmpty {
                catalogState = .loaded
            }
        }
        .onChange(of: sessionStore.sidebarProjects.map(\.id)) { _, _ in
            synchronizeSelection()
            if !sessionStore.sidebarProjects.isEmpty {
                catalogState = .loaded
            }
        }
        .sheet(isPresented: $isPresentingOpenWorkspace) {
            OpenWorkspaceSheet()
        }
        .background(tokens.background.ignoresSafeArea())
    }

    private func workspaceBrowser(tokens: ThemeTokens) -> some View {
        VStack(spacing: 0) {
            workspaceStrip(tokens: tokens)

            Divider()
                .overlay(tokens.border.opacity(0.7))

            if let selectedProject {
                workspaceDetailForm(project: selectedProject)
                    .id(selectedProject.id)
                    .refreshable {
                        await refreshCatalog()
                    }
            } else if !sessionStore.sidebarProjects.isEmpty {
                ContentUnavailableView("请选择工作区", systemImage: "folder")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(tokens.background.ignoresSafeArea())
        .overlay {
            if sessionStore.sidebarProjects.isEmpty, catalogState != .loading {
                ContentUnavailableView {
                    Label(emptyWorkspaceTitle, systemImage: emptyWorkspaceSymbol)
                } description: {
                    Text(emptyWorkspaceMessage)
                } actions: {
                    Button("打开目录") {
                        isPresentingOpenWorkspace = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tokens.primaryAction)
                }
            }
        }
    }

    private func workspaceStrip(tokens: ThemeTokens) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    if catalogState == .loading && sessionStore.sidebarProjects.isEmpty {
                        ForEach(0..<4, id: \.self) { index in
                            WorkspaceLibraryCard(
                                project: AgentProject(id: "loading-\(index)", name: "正在加载工作区", path: "/Users/you/code/project"),
                                sessionCount: 0,
                                worktreeCount: 0,
                                isUnavailable: false,
                                isSelected: false,
                                tokens: tokens
                            ) {}
                            .frame(width: 320)
                            .redacted(reason: .placeholder)
                        }
                    } else {
                        ForEach(sessionStore.sidebarProjects) { project in
                            WorkspaceLibraryCard(
                                project: project,
                                sessionCount: sessionStore.sessions(forProjectID: project.id).count,
                                worktreeCount: sessionStore.managedWorktrees(rootProjectID: sessionStore.rootProjectID(forProjectID: project.id)).count,
                                isUnavailable: sessionStore.isWorkspaceUnavailable(project.id),
                                isSelected: selectedWorkspaceID == project.id,
                                tokens: tokens
                            ) {
                                // 工作区页面只更新本地浏览选择，避免切换卡片时意外改变当前会话上下文。
                                selectedWorkspaceID = project.id
                            }
                            .frame(width: 320)
                            .id(project.id)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            .frame(height: 178)
            .onChange(of: selectedWorkspaceID) { _, selectedID in
                guard let selectedID else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
            .onAppear {
                guard let selectedWorkspaceID else { return }
                // 恢复已有选择时主动定位卡片，保证选中项不会留在横向列表的屏幕外。
                DispatchQueue.main.async {
                    proxy.scrollTo(selectedWorkspaceID, anchor: .center)
                }
            }
        }
        .accessibilityLabel("工作区列表")
    }

    private func workspaceDetailForm(project: AgentProject) -> some View {
        WorkspaceDetailForm(
            project: project,
            sessionCount: sessionStore.sessions(forProjectID: project.id).count,
            worktreeCount: sessionStore.managedWorktrees(rootProjectID: sessionStore.rootProjectID(forProjectID: project.id)).count,
            isUnavailable: sessionStore.isWorkspaceUnavailable(project.id),
            lastActivity: lastActivityText(for: project),
            isShownInSessions: sessionStore.isWorkspaceShownInSessions(project.id),
            claudeChannelAvailable: sessionStore.hasClaudeRuntimeChannel,
            onToggleSessionVisibility: {
                sessionStore.toggleWorkspaceInSessions(project)
            },
            onOpenInSessions: {
                onOpenInSessions(project)
            },
            onStartSession: { runtimeChoice in
                onStartSession(project, runtimeChoice)
            }
        )
    }

    private var selectedProject: AgentProject? {
        guard let selectedWorkspaceID else {
            return nil
        }
        return sessionStore.sidebarProjects.first { $0.id == selectedWorkspaceID }
    }

    private var emptyWorkspaceTitle: String {
        if case .failed = catalogState { return "无法加载工作区" }
        return "还没有工作区"
    }

    private var emptyWorkspaceSymbol: String {
        if case .failed = catalogState { return "exclamationmark.triangle" }
        return "folder.badge.plus"
    }

    private var emptyWorkspaceMessage: String {
        if case .failed(let message) = catalogState { return message }
        return "打开目录后，可以在这里浏览项目和创建会话。"
    }

    private func synchronizeSelection() {
        let projects = sessionStore.sidebarProjects
        guard !projects.isEmpty else {
            selectedWorkspaceID = nil
            return
        }
        if let selectedWorkspaceID,
           projects.contains(where: { $0.id == selectedWorkspaceID }) {
            return
        }
        selectedWorkspaceID = sessionStore.selectedProjectID.flatMap { selectedID in
            projects.contains(where: { $0.id == selectedID }) ? selectedID : nil
        } ?? projects.first?.id
    }

    private func refreshCatalog() async {
        catalogState = .loading
        do {
            try await sessionStore.refreshWorkspaceCatalog()
            guard !Task.isCancelled else {
                return
            }
            catalogState = .loaded
        } catch is CancellationError {
            return
        } catch {
            catalogState = .failed(error.localizedDescription)
        }
    }

    private func lastActivityText(for project: AgentProject) -> String {
        guard let date = sessionStore.sessions(forProjectID: project.id)
            .compactMap({ $0.updatedAt ?? $0.createdAt })
            .max()
        else {
            return "暂无"
        }
        return Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private enum CatalogState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }
}

private struct WorkspaceLibraryCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    let project: AgentProject
    let sessionCount: Int
    let worktreeCount: Int
    let isUnavailable: Bool
    let isSelected: Bool
    let tokens: ThemeTokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isUnavailable ? "folder.badge.questionmark" : "folder.fill")
                        .font(themeStore.uiFont(size: 22, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isUnavailable ? tokens.warning : tokens.primaryAction)
                        .frame(width: 44, height: 44)
                        .background((isUnavailable ? tokens.warning : tokens.livelyAccent).opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name)
                            .font(themeStore.uiFont(.headline, weight: .semibold))
                            .foregroundStyle(tokens.primaryText)
                            .lineLimit(1)
                        Text(project.path)
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.down")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(isSelected ? tokens.primaryAction : tokens.tertiaryText)
                }

                HStack(spacing: 8) {
                    metric("\(sessionCount)", title: "会话", systemImage: "bubble.left.and.bubble.right")
                    metric("\(worktreeCount)", title: "Worktree", systemImage: "arrow.triangle.branch")
                    Spacer(minLength: 0)
                    Label(isUnavailable ? "需要重试" : "可访问", systemImage: isUnavailable ? "exclamationmark.triangle" : "checkmark.circle.fill")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(isUnavailable ? tokens.warning : tokens.success)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
            .background(tokens.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isSelected ? tokens.primaryAction : tokens.border.opacity(0.72),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("工作区 \(project.name)，\(sessionCount) 个会话\(isSelected ? "，已选择" : "")")
    }

    private func metric(_ value: String, title: String, systemImage: String) -> some View {
        Label("\(value) \(title)", systemImage: systemImage)
            .font(themeStore.uiFont(.caption, weight: .medium))
            .foregroundStyle(tokens.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tokens.elevatedSurface.opacity(0.66), in: Capsule())
    }
}

private struct WorkspaceDetailForm: View {
    let project: AgentProject
    let sessionCount: Int
    let worktreeCount: Int
    let isUnavailable: Bool
    let lastActivity: String
    let isShownInSessions: Bool
    let claudeChannelAvailable: Bool
    let onToggleSessionVisibility: () -> Void
    let onOpenInSessions: () -> Void
    let onStartSession: (WorkspaceSessionRuntimeChoice) -> Void

    var body: some View {
        Form {
            Section("工作区") {
                LabeledContent("名称", value: project.name)
                LabeledContent("路径") {
                    Text(project.path)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Section("概览") {
                LabeledContent("会话", value: "\(sessionCount) 个")
                LabeledContent("Worktree", value: "\(worktreeCount) 个")
                LabeledContent("状态", value: isUnavailable ? "需要重试" : "可访问")
                LabeledContent("最近活动", value: lastActivity)
            }

            Section("会话") {
                Button("在会话中打开", action: onOpenInSessions)
                ForEach(WorkspaceSessionRuntimeChoice.available(claudeChannelAvailable: claudeChannelAvailable)) { choice in
                    Button {
                        // thread 创建时就绑定 runtime；这里必须把用户选择一路传到 SessionStore。
                        onStartSession(choice)
                    } label: {
                        Label(choice.title, systemImage: choice.systemImage)
                    }
                }
                Button(isShownInSessions ? "从会话侧栏隐藏" : "显示在会话侧栏", action: onToggleSessionVisibility)
            }
        }
        .formStyle(.grouped)
    }
}
