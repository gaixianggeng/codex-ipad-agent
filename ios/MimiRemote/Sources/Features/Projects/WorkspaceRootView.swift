import SwiftUI

/// 工作区只维护本地浏览选择。只有用户明确进入会话或新建会话时，才交给 SessionStore 改变活动上下文。
struct WorkspaceRootView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let onOpenInSessions: (AgentProject) -> Void
    let onStartSession: (AgentProject) -> Void

    @State private var selectedWorkspaceID: String?
    @State private var catalogState: CatalogState = .idle
    @State private var isPresentingOpenWorkspace = false

    init(
        onOpenInSessions: @escaping (AgentProject) -> Void,
        onStartSession: @escaping (AgentProject) -> Void
    ) {
        self.onOpenInSessions = onOpenInSessions
        self.onStartSession = onStartSession
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationSplitView {
            workspaceList(tokens: tokens)
                .navigationTitle("工作区")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isPresentingOpenWorkspace = true
                        } label: {
                            Label("打开目录", systemImage: "folder.badge.plus")
                        }
                    }
                }
        } detail: {
            workspaceDetail(tokens: tokens)
        }
        .navigationSplitViewStyle(.balanced)
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

    private func workspaceList(tokens: ThemeTokens) -> some View {
        List(selection: $selectedWorkspaceID) {
            if catalogState == .loading && sessionStore.sidebarProjects.isEmpty {
                Section {
                    ForEach(0..<4, id: \.self) { _ in
                        Label("正在加载工作区", systemImage: "folder")
                            .redacted(reason: .placeholder)
                    }
                }
            } else {
                Section {
                    ForEach(sessionStore.sidebarProjects) { project in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name)
                                Text(project.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: sessionStore.isWorkspaceUnavailable(project.id) ? "folder.badge.questionmark" : "folder")
                                .foregroundStyle(sessionStore.isWorkspaceUnavailable(project.id) ? tokens.warning : tokens.accent)
                        }
                        .tag(project.id)
                        .accessibilityLabel("工作区 \(project.name)")
                    }
                } header: {
                    Text("最近工作区")
                }
            }
        }
        .listStyle(.sidebar)
        .refreshable {
            await refreshCatalog()
        }
        .overlay {
            if case .failed(let message) = catalogState, sessionStore.sidebarProjects.isEmpty {
                ContentUnavailableView {
                    Label("无法加载工作区", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") {
                        Task { await refreshCatalog() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func workspaceDetail(tokens: ThemeTokens) -> some View {
        if let project = selectedProject {
            WorkspaceDetailForm(
                project: project,
                sessionCount: sessionStore.sessions(forProjectID: project.id).count,
                worktreeCount: sessionStore.managedWorktrees(rootProjectID: sessionStore.rootProjectID(forProjectID: project.id)).count,
                isUnavailable: sessionStore.isWorkspaceUnavailable(project.id),
                lastActivity: lastActivityText(for: project),
                isShownInSessions: sessionStore.isWorkspaceShownInSessions(project.id),
                onToggleSessionVisibility: {
                    sessionStore.toggleWorkspaceInSessions(project)
                },
                onOpenInSessions: {
                    onOpenInSessions(project)
                },
                onStartSession: {
                    onStartSession(project)
                }
            )
        } else if catalogState == .loading {
            ProgressView("正在加载工作区")
        } else if sessionStore.sidebarProjects.isEmpty {
            ContentUnavailableView {
                Label("还没有工作区", systemImage: "folder.badge.plus")
            } description: {
                Text("打开目录后，可以在这里浏览项目和创建会话。")
            } actions: {
                Button("打开目录") {
                    isPresentingOpenWorkspace = true
                }
            }
        } else {
            ContentUnavailableView("选择一个工作区", systemImage: "folder")
        }
    }

    private var selectedProject: AgentProject? {
        guard let selectedWorkspaceID else {
            return nil
        }
        return sessionStore.sidebarProjects.first { $0.id == selectedWorkspaceID }
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

private struct WorkspaceDetailForm: View {
    let project: AgentProject
    let sessionCount: Int
    let worktreeCount: Int
    let isUnavailable: Bool
    let lastActivity: String
    let isShownInSessions: Bool
    let onToggleSessionVisibility: () -> Void
    let onOpenInSessions: () -> Void
    let onStartSession: () -> Void

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
                Button("新建会话", action: onStartSession)
                    .buttonStyle(.borderedProminent)
                Button(isShownInSessions ? "从会话侧栏隐藏" : "显示在会话侧栏", action: onToggleSessionVisibility)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
