import SwiftUI
import QuickLook

struct ProjectSidebarView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isPresentingOpenWorkspace = false
    @State private var isPresentingWorktreeManager = false
    @State private var worktreeManagerRootProjectID = ""
    @State private var worktreeCreateProject: AgentProject?
    var showsSessions = true

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let selectedProjectID = sessionStore.selectedProjectID
        let selectedSessionID = sessionStore.selectedSessionID

        List {
            Section {
                ForEach(sessionStore.filteredSidebarProjects) { project in
                    let snapshot = sessionStore.sessionListSnapshot(forProjectID: project.id)

                    ProjectRow(
                        project: project,
                        isActiveProject: project.id == selectedProjectID,
                        isSelected: project.id == selectedProjectID && selectedSessionID == nil,
                        isExpanded: snapshot.isExpanded,
                        isLoading: snapshot.isLoadingMore,
                        isUnavailable: sessionStore.isWorkspaceUnavailable(project.id),
                        onToggle: {
                            Task {
                                if showsSessions {
                                    await sessionStore.toggleProjectExpansion(project)
                                } else {
                                    await sessionStore.selectProject(project)
                                }
                            }
                        },
                        onNewSession: {
                            Task { await sessionStore.startNewSession(in: project) }
                        },
                        onCreateWorktree: {
                            worktreeCreateProject = project
                        },
                        onManageWorktrees: {
                            worktreeManagerRootProjectID = sessionStore.rootProjectID(forProjectID: project.id)
                            isPresentingWorktreeManager = true
                        },
                        onRetry: {
                            Task { await sessionStore.retryWorkspace(project) }
                        },
                        onForget: {
                            sessionStore.forgetWorkspace(project)
                        }
                    )
                    .equatable()
                    .sidebarListRow()

                    if showsSessions && snapshot.isExpanded {
                        ProjectSessionRows(
                            project: project,
                            snapshot: snapshot,
                            selectedSessionID: selectedSessionID,
                            isLoading: sessionStore.isLoading
                        )
                    }
                }
            } header: {
                HStack {
                    Text("项目")
                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.tertiaryText)
                    Spacer()
                    Button {
                        Task { await sessionStore.refreshAll(autoAttach: false) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    Button {
                        isPresentingOpenWorkspace = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("打开路径")
                }
            }
        }
        .listStyle(.sidebar)
        .contentMargins(.top, 6, for: .scrollContent)
        .contentMargins(.bottom, 12, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(tokens.background)
        .tint(tokens.accent)
        .searchable(text: $sessionStore.sessionSearchQuery, placement: searchPlacement, prompt: "搜索会话")
        .sheet(isPresented: $isPresentingOpenWorkspace) {
            OpenWorkspaceSheet()
        }
        .sheet(isPresented: $isPresentingWorktreeManager) {
            WorktreeManagerSheet(rootProjectID: worktreeManagerRootProjectID)
        }
        .sheet(item: $worktreeCreateProject) { project in
            CreateWorktreeSheet(project: project)
        }
        .overlay {
            if sessionStore.sidebarProjects.isEmpty && !sessionStore.isLoading {
                ContentUnavailableView {
                    Label("没有已打开的工作区", systemImage: "folder.badge.plus")
                } description: {
                    Text("选择已授权的工作目录后，这里会保留最近打开的项目。")
                } actions: {
                    Button {
                        isPresentingOpenWorkspace = true
                    } label: {
                        Label("打开路径", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if sessionStore.filteredSidebarProjects.isEmpty && !sessionStore.isLoading && sessionStore.isSessionSearchActive {
                ContentUnavailableView(
                    "没有匹配的会话",
                    systemImage: "magnifyingglass",
                    description: Text("换个关键词试试。")
                )
            }
        }
    }

    private var searchPlacement: SearchFieldPlacement {
        // iPhone 没有真正的 sidebar 搜索区，放到导航栏抽屉里才是系统原生的窄屏入口。
        horizontalSizeClass == .compact ? .navigationBarDrawer(displayMode: .automatic) : .sidebar
    }
}

private struct OpenWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var path = ""
    @State private var isOpening = false
    @State private var localError: String?

    @State private var browsePath: String?
    @State private var browseParentPath: String?
    @State private var browseEntries: [DirectoryEntry] = []
    @State private var browseTruncated = false
    @State private var isBrowsing = false
    @State private var browseError: String?
    @State private var previewURL: URL?
    @State private var previewError: String?
    @State private var previewingPath: String?
    // 快速连点目录时让最后一次请求胜出，避免慢响应把列表回写成旧目录。
    @State private var browseRequestID = 0

    var body: some View {
        NavigationStack {
            Form {
                currentDirectorySection
                childDirectoriesSection

                if let localError {
                    Section {
                        Text(localError)
                            .font(themeStore.uiFont(size: 13))
                            .foregroundStyle(.red)
                    } header: {
                        Text("打开失败")
                    }
                }

                Section {
                    TextField("/Users/me/finance", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await open(path: path) }
                    } label: {
                        Label(isOpening ? "正在打开" : "打开输入的路径", systemImage: "folder.badge.plus")
                    }
                    .disabled(!canOpenTypedPath)
                } header: {
                    Text("手动输入路径")
                } footer: {
                    Text("可直接粘贴开发环境中的绝对路径；目录需在已授权范围内（默认是用户 Home）。")
                }
            }
            .navigationTitle("打开工作区")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .task {
                // 默认进入服务端浏览根（第一个 scan root），失败时仍可手动输入路径。
                await browse(to: "")
            }
            .onChange(of: path) { _, _ in
                localError = nil
            }
            .quickLookPreview($previewURL)
        }
    }

    @ViewBuilder
    private var currentDirectorySection: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(themeStore.uiFont(size: 20, weight: .semibold))
                        .foregroundStyle(tokens.accent)
                        .frame(width: 38, height: 38)
                        .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(currentDirectoryName)
                            .font(themeStore.uiFont(size: 16, weight: .semibold))
                            .foregroundStyle(tokens.primaryText)
                            .lineLimit(1)
                        Text(browsePath ?? "正在定位...")
                            .font(themeStore.uiFont(size: 12))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(2)
                            .truncationMode(.head)
                    }

                    Spacer(minLength: 10)

                    if let browseParentPath {
                        Button {
                            Task { await browse(to: browseParentPath) }
                        } label: {
                            Label("上一级", systemImage: "arrow.up")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isBrowsing)
                        .accessibilityLabel("返回上一级")
                    }
                }

                Button {
                    if let browsePath {
                        Task { await open(path: browsePath) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(isOpening ? "正在打开" : "打开当前目录")
                        Spacer(minLength: 0)
                    }
                    .font(themeStore.uiFont(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(browsePath == nil || isOpening || isBrowsing)
            }
            .padding(.vertical, 4)
        } header: {
            Text("当前位置")
        }
    }

    @ViewBuilder
    private var childDirectoriesSection: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Section {
            if isBrowsing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在加载目录…")
                        .foregroundStyle(.secondary)
                }
            } else if let browseError {
                Text(browseError)
                    .font(themeStore.uiFont(size: 13))
                    .foregroundStyle(.red)
                Button {
                    Task { await browse(to: browsePath ?? "") }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
            } else if browseEntries.isEmpty {
                Text("没有可进入的子目录或可预览文件")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(browseEntries) { entry in
                    Button {
                        if entry.isDir {
                            Task { await browse(to: entry.path) }
                        } else {
                            Task { await preview(entry) }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: entry.isDir ? "folder" : "doc.text")
                                .font(themeStore.uiFont(size: 18, weight: .regular))
                                .foregroundStyle(tokens.accent)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(themeStore.uiFont(size: 15, weight: .medium))
                                    .foregroundStyle(tokens.primaryText)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if previewingPath == entry.path {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: entry.isDir ? "chevron.right" : "eye")
                                    .font(themeStore.uiFont(size: 12, weight: .semibold))
                                    .foregroundStyle(tokens.tertiaryText)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isOpening || isBrowsing || previewingPath != nil || (!entry.canBrowse && !entry.isPreviewable))
                }

                if let previewError {
                    Text(previewError)
                        .font(themeStore.uiFont(size: 13))
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("内容")
        } footer: {
            if browseTruncated {
                Text("目录过大，仅显示前面部分；其余内容请用下方手动输入路径打开目录。")
            } else {
                Text("隐藏目录、Library 与常见缓存目录不会显示；文件仅用于预览，不能作为工作区打开。")
            }
        }
    }

    private var currentDirectoryName: String {
        guard let browsePath, !browsePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "正在定位"
        }
        let parts = browsePath.split(separator: "/").map(String.init)
        return parts.last ?? browsePath
    }

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canOpenTypedPath: Bool {
        !isOpening && !trimmedPath.isEmpty
    }

    private func browse(to target: String) async {
        browseRequestID += 1
        let requestID = browseRequestID
        isBrowsing = true
        browseError = nil
        do {
            let response = try await sessionStore.listDirectories(path: target)
            guard requestID == browseRequestID else {
                return
            }
            browsePath = response.path
            browseParentPath = response.parentPath
            browseEntries = response.entries
            browseTruncated = response.truncated ?? false
            previewError = nil
            isBrowsing = false
        } catch {
            guard requestID == browseRequestID else {
                return
            }
            browseError = userFacingBrowseError(error)
            isBrowsing = false
        }
    }

    private func userFacingBrowseError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 || status == 405 {
            return "当前 agentd 版本还不支持目录浏览，请升级 agentd；也可以直接在下方输入路径。"
        }
        if case AgentAPIError.server(let status, _) = error, status == 403 {
            return "该目录不在授权范围内或不可访问。"
        }
        return error.localizedDescription
    }

    private func preview(_ entry: DirectoryEntry) async {
        guard entry.isPreviewable else {
            return
        }
        let targetPath = entry.path
        previewingPath = targetPath
        previewError = nil
        defer {
            if previewingPath == targetPath {
                previewingPath = nil
            }
        }
        do {
            previewURL = try await sessionStore.previewFile(path: targetPath)
        } catch {
            previewError = userFacingPreviewError(error)
        }
    }

    private func userFacingPreviewError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 || status == 405 {
            return "当前 agentd 版本还不支持文件预览，请升级 agentd。"
        }
        if case AgentAPIError.server(let status, _) = error, status == 403 {
            return "该文件不在授权范围内或不可访问。"
        }
        if case AgentAPIError.server(let status, _) = error, status == 413 {
            return "文件过大，暂不支持预览。"
        }
        return error.localizedDescription
    }

    private func open(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            localError = "请输入开发环境中的目录路径"
            return
        }
        isOpening = true
        localError = nil
        defer { isOpening = false }
        if await sessionStore.openWorkspace(path: targetPath) {
            dismiss()
        } else {
            localError = userFacingOpenWorkspaceError(sessionStore.errorMessage, path: targetPath)
        }
    }

    private func userFacingOpenWorkspaceError(_ message: String?, path: String) -> String {
        let fallback = "无法打开“\(path)”"
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        let lowercased = message.lowercased()
        if lowercased.contains("allowlist") ||
            message.contains("允许范围") ||
            message.contains("HTTP 403") {
            return "“\(path)”还不在已授权范围内。默认浏览授权根是用户 Home；如改过配置，请在本地开发环境中调整 browse_roots（或 AGENTD_BROWSE_ROOTS）后重试。"
        }
        return message
    }
}

private struct ProjectSessionRows: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let project: AgentProject
    let snapshot: ProjectSessionListSnapshot
    let selectedSessionID: SessionID?
    let isLoading: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        if snapshot.isEmpty && !isLoading {
            Text("暂无历史会话")
                .font(themeStore.uiFont(size: 12))
                .foregroundStyle(tokens.tertiaryText)
                .padding(.leading, 34)
                .padding(.vertical, 6)
                .sidebarListRow()
        }

        ForEach(snapshot.visibleSessions) { session in
            let isPinned = sessionStore.isSessionPinned(session.id)
            let isArchived = sessionStore.isSessionArchived(session.id)
            let reminder = sessionStore.sessionReminder(for: session.id)
            let foregroundActivity = sessionStore.foregroundActivity(for: session.id)
            SessionRow(
                session: session,
                foregroundActivity: foregroundActivity,
                isSelected: session.id == selectedSessionID,
                isPinned: isPinned,
                isArchived: isArchived,
                reminder: reminder,
                isObserving: sessionStore.isSessionObserving(session)
            )
                .equatable()
                // List 行内的 Button 会被 UICollectionView 的 delaysContentTouches 拖慢高亮，
                // 改用 contentShape + onTapGesture，让点击在抬手时立即响应。
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await sessionStore.selectSession(session) }
                }
                .contextMenu {
                    if sessionStore.isSessionObserving(session) {
                        Button {
                            sessionStore.takeOverSession(session)
                        } label: {
                            Label("接管到 iPad", systemImage: "hand.raised.fill")
                        }
                    }

                    Button {
                        sessionStore.toggleSessionPinned(session)
                    } label: {
                        Label(isPinned ? "取消置顶" : "置顶", systemImage: isPinned ? "pin.slash" : "pin")
                    }

                    Button {
                        Task { await sessionStore.handoffSessionToWorktree(session) }
                    } label: {
                        Label("转到新 Git Worktree", systemImage: "arrow.triangle.branch")
                    }
                    .disabled(session.isRunning || sessionStore.isCreatingWorktree)

                    Menu {
                        Button {
                            Task { await sessionStore.scheduleSessionReminder(session, after: 30 * 60) }
                        } label: {
                            Label("30 分钟后", systemImage: "timer")
                        }
                        Button {
                            Task { await sessionStore.scheduleSessionReminder(session, after: 2 * 60 * 60) }
                        } label: {
                            Label("2 小时后", systemImage: "clock")
                        }
                        Button {
                            Task { await sessionStore.scheduleSessionReminder(session, after: 24 * 60 * 60) }
                        } label: {
                            Label("明天", systemImage: "calendar")
                        }
                        if reminder != nil {
                            Button(role: .destructive) {
                                sessionStore.clearSessionReminder(session)
                            } label: {
                                Label("清除提醒", systemImage: "bell.slash")
                            }
                        }
                    } label: {
                        Label("提醒", systemImage: reminder == nil ? "bell" : "bell.fill")
                    }

                    Button(role: isArchived ? nil : .destructive) {
                        Task { await sessionStore.toggleSessionArchivedRemote(session) }
                    } label: {
                        Label(isArchived ? "取消归档" : "归档", systemImage: isArchived ? "archivebox.fill" : "archivebox")
                    }
                }
                .padding(.leading, 34)
                .sidebarListRow()
        }

        if snapshot.shouldShowActionRow {
            HStack(spacing: 6) {
                if snapshot.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tokens.tertiaryText)
                } else {
                    Image(systemName: snapshot.isShowingAll && !snapshot.canLoadMore ? "chevron.up" : "ellipsis")
                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                }
                Text(snapshot.actionTitle)
                    .lineLimit(1)
            }
            .font(themeStore.uiFont(size: 12, weight: .medium))
            .foregroundStyle(tokens.tertiaryText)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !snapshot.isLoadingMore else {
                        return
                    }
                    Task {
                        if snapshot.isShowingAll && snapshot.canLoadMore {
                            await sessionStore.loadMoreSessions(projectID: project.id)
                        } else {
                            await sessionStore.toggleSessionListExpansion(projectID: project.id)
                        }
                    }
                }
                .padding(.leading, 42)
                .padding(.vertical, 5)
                .sidebarListRow()
        }
    }
}

private struct ProjectRow: View, Equatable {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let project: AgentProject
    let isActiveProject: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let isLoading: Bool
    let isUnavailable: Bool
    let onToggle: () -> Void
    let onNewSession: () -> Void
    let onCreateWorktree: () -> Void
    let onManageWorktrees: () -> Void
    let onRetry: () -> Void
    let onForget: () -> Void

    static func == (lhs: ProjectRow, rhs: ProjectRow) -> Bool {
        lhs.project == rhs.project
            && lhs.isActiveProject == rhs.isActiveProject
            && lhs.isSelected == rhs.isSelected
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isLoading == rhs.isLoading
            && lhs.isUnavailable == rhs.isUnavailable
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 8) {
            // 整块左侧区域作为展开/收起的点击目标。用 onTapGesture 绕开 List 行内 Button
            // 在 UICollectionView 下的 delaysContentTouches 高亮延迟。
            HStack(spacing: 10) {
                Image(systemName: isUnavailable ? "exclamationmark.triangle.fill" : (isActiveProject || isExpanded ? "folder.fill" : "folder"))
                    .frame(width: 20)
                    .foregroundStyle(isUnavailable ? Color.orange : (isActiveProject ? tokens.accent : tokens.secondaryText))
                Text(project.name)
                    .font(themeStore.uiFont(size: 16, weight: .semibold))
                    .foregroundStyle(isUnavailable ? tokens.tertiaryText : tokens.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if isUnavailable {
                    Text("不可用")
                        .font(themeStore.uiFont(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tokens.tertiaryText)
                } else {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.tertiaryText)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            Image(systemName: "square.and.pencil")
                .font(themeStore.uiFont(size: 15, weight: .medium))
                .foregroundStyle(tokens.primaryText.opacity(0.86))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .onTapGesture(perform: onNewSession)
                .accessibilityLabel("新建会话")

            Menu {
                if isUnavailable {
                    Button(action: onRetry) {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                }
                Button(action: onCreateWorktree) {
                    Label("新建 Git Worktree", systemImage: "square.stack.3d.up")
                }
                .disabled(isUnavailable)
                Button(action: onManageWorktrees) {
                    Label("管理 Git Worktree", systemImage: "wrench.and.screwdriver")
                }
                Button(role: .destructive, action: onForget) {
                    Label("从当前设备移除", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(themeStore.uiFont(size: 15, weight: .semibold))
                    .foregroundStyle(tokens.secondaryText)
                    .frame(width: 24, height: 28)
            }
            .menuStyle(.button)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            SidebarSelectionBackground(isSelected: isSelected, tint: tokens.selectionFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? tokens.accent.opacity(0.45) : Color.clear, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SessionRow: View, Equatable {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let session: AgentSession
    let foregroundActivity: SessionForegroundActivity?
    let isSelected: Bool
    let isPinned: Bool
    let isArchived: Bool
    let reminder: SessionReminder?
    let isObserving: Bool

    static func == (lhs: SessionRow, rhs: SessionRow) -> Bool {
        lhs.session == rhs.session
            && lhs.foregroundActivity == rhs.foregroundActivity
            && lhs.isSelected == rhs.isSelected
            && lhs.isPinned == rhs.isPinned
            && lhs.isArchived == rhs.isArchived
            && lhs.reminder == rhs.reminder
            && lhs.isObserving == rhs.isObserving
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(themeStore.uiFont(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.accent)
                        .accessibilityLabel("已置顶")
                }
                if isArchived {
                    Image(systemName: "archivebox.fill")
                        .font(themeStore.uiFont(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.tertiaryText)
                        .accessibilityLabel("已归档")
                }
                if reminder != nil {
                    Image(systemName: "bell.fill")
                        .font(themeStore.uiFont(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("已设置提醒")
                }
                Text(session.title)
                    .font(themeStore.uiFont(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? tokens.primaryText : tokens.secondaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                trailingMetadata
            }

            if let preview = session.preview, !preview.isEmpty {
                Text(preview)
                    .font(themeStore.uiFont(size: 12))
                    .foregroundStyle(isSelected ? tokens.secondaryText : tokens.tertiaryText)
                    .lineLimit(1)
            }

            if shouldShowStatusLine {
                HStack(spacing: 6) {
                    statusCapsule(statusSummary)
                    ForEach(Array(statusBadges.prefix(2))) { badge in
                        statusCapsule(badge)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background {
            SidebarSelectionBackground(isSelected: isSelected, tint: tokens.selectionFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? tokens.accent.opacity(0.45) : Color.clear, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var trailingMetadata: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        if shouldShowStatusLine {
            if statusSummary.showsSpinner {
                ProgressView()
                    .controlSize(.mini)
                    .tint(tint(for: statusSummary.tone))
                    .accessibilityLabel(statusSummary.title)
            } else {
                Image(systemName: statusSummary.systemImage)
                    .font(themeStore.uiFont(size: 13, weight: .semibold))
                    .foregroundStyle(tint(for: statusSummary.tone))
                    .accessibilityLabel(statusSummary.title)
            }
        } else if let updatedAt = session.updatedAt {
            Text(Self.minuteTimeFormatter.string(from: updatedAt))
                .font(themeStore.uiFont(size: 12, weight: .medium))
                .foregroundStyle(tokens.tertiaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var statusSummary: AgentSessionDisplayStatus {
        if isObserving {
            return AgentSessionDisplayStatus(title: "观察中", systemImage: "eye", tone: .neutral, showsSpinner: false)
        }
        return session.displayStatus(foregroundActivity: foregroundActivity)
    }

    private var statusDotColor: Color {
        tint(for: statusSummary.tone)
    }

    private var statusBadges: [AgentSessionStatusBadge] {
        session.statusBadges(foregroundActivity: foregroundActivity).filter { badge in
            // 主胶囊已经展示当前阶段；下方只保留补充信息，避免一行里重复“等待回复”。
            badge.id != "foreground-\(foregroundActivity?.title ?? "")"
        }
    }

    private var shouldShowStatusLine: Bool {
        session.isRunning
            || foregroundActivity != nil
            || session.pendingApproval != nil
            || session.status == SessionStatus.waitingForInput.rawValue
            || session.status == SessionStatus.waitingForApproval.rawValue
            || session.status == SessionStatus.failed.rawValue
            || session.goal != nil
    }

    private func statusCapsule(_ status: AgentSessionDisplayStatus) -> some View {
        HStack(spacing: 4) {
            if status.showsSpinner {
                ProgressView()
                    .controlSize(.mini)
                    .tint(tint(for: status.tone))
            } else {
                Image(systemName: status.systemImage)
            }
            Text(status.title)
                .lineLimit(1)
        }
        .font(themeStore.uiFont(size: 11, weight: .medium))
        .foregroundStyle(tint(for: status.tone))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint(for: status.tone).opacity(0.10), in: Capsule())
    }

    private func statusCapsule(_ badge: AgentSessionStatusBadge) -> some View {
        Label(badge.title, systemImage: badge.systemImage)
            .font(themeStore.uiFont(size: 11, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(tint(for: badge.tone))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint(for: badge.tone).opacity(0.10), in: Capsule())
    }

    private func tint(for tone: AgentSessionStatusTone) -> Color {
        themeStore.tokens(for: colorScheme).tint(for: tone)
    }

    // 左侧列表只展示到分钟，避免 relative 时间按秒触发刷新。
    private static let minuteTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct SidebarSelectionBackground: View {
    let isSelected: Bool
    let tint: Color

    var body: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint)
        }
    }
}

private struct WorktreeManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    let rootProjectID: String
    @State private var pendingDelete: WorktreeListItem?

    private var worktrees: [WorktreeListItem] {
        sessionStore.managedWorktrees(rootProjectID: rootProjectID)
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            List {
                if let message = sessionStore.worktreeErrorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(size: 13, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    ForEach(worktrees) { item in
                        WorktreeManagerRow(
                            item: item,
                            isRunning: sessionStore.hasRunningSession(in: item),
                            isBusy: sessionStore.isDeletingWorktree,
                            onOpen: {
                                Task {
                                    _ = await sessionStore.openManagedWorktree(item)
                                    dismiss()
                                }
                            },
                            onDelete: {
                                pendingDelete = item
                            }
                        )
                    }
                }
                Section {
                    Button {
                        Task { await sessionStore.pruneMissingManagedWorktrees() }
                    } label: {
                        if sessionStore.isPruningWorktrees {
                            Label("正在清理", systemImage: "hourglass")
                        } else {
                            Label("清理丢失登记", systemImage: "checklist.unchecked")
                        }
                    }
                    .disabled(sessionStore.isRefreshingWorktrees || sessionStore.isDeletingWorktree || sessionStore.isPruningWorktrees)
                } footer: {
                    Text("只移除已经不存在的 agentd Worktree registry 登记，不删除任何仍存在的 checkout。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Git Worktree")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            .overlay {
                if worktrees.isEmpty && !sessionStore.isRefreshingWorktrees {
                    ContentUnavailableView(
                        "没有 Git Worktree",
                        systemImage: "square.stack.3d.up",
                        description: Text("当前项目没有已管理的 Git Worktree。")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await sessionStore.refreshManagedWorktrees() }
                    } label: {
                        if sessionStore.isRefreshingWorktrees {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(sessionStore.isRefreshingWorktrees || sessionStore.isPruningWorktrees)
                    .accessibilityLabel("刷新 Git Worktree")
                }
            }
        }
        .task {
            await sessionStore.refreshManagedWorktrees()
        }
        .confirmationDialog("删除 Git Worktree？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDelete = nil
                }
            }
        ), titleVisibility: .visible) {
            if let item = pendingDelete {
                Button("删除 \(item.workspace.name)", role: .destructive) {
                    let target = item
                    pendingDelete = nil
                    Task { await sessionStore.deleteManagedWorktree(target, force: false) }
                }
                Button("强制删除并丢弃改动", role: .destructive) {
                    let target = item
                    pendingDelete = nil
                    Task { await sessionStore.deleteManagedWorktree(target, force: true) }
                }
            }
            Button("取消", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("普通删除会保留 Git 对未提交改动的保护；强制删除会丢弃该 Git Worktree 内的未提交改动。")
        }
    }
}

private struct CreateWorktreeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    let project: AgentProject
    @State private var name = ""
    @State private var base = ""
    @State private var branch = ""
    @State private var didApplyDefaultBase = false

    private var canCreate: Bool {
        !sessionStore.isCreatingWorktree
    }

    private var branchList: WorktreeBranchListResponse? {
        sessionStore.worktreeBranches(path: project.path)
    }

    private var baseBranchItems: [WorktreeBranchItem] {
        branchList?.branches ?? []
    }

    private var branchErrorMessage: String? {
        sessionStore.worktreeBranchError(path: project.path)
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            Form {
                Section {
                    LabeledContent("项目") {
                        Text(project.name)
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(1)
                    }
                    TextField("名称", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack(spacing: 8) {
                        TextField("Base", text: $base)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if sessionStore.isRefreshingWorktreeBranches && baseBranchItems.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                        } else if !baseBranchItems.isEmpty {
                            Menu {
                                ForEach(baseBranchItems) { item in
                                    Button {
                                        base = item.name
                                        didApplyDefaultBase = true
                                    } label: {
                                        Label(branchMenuTitle(item), systemImage: branchIconName(item))
                                    }
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                                    .foregroundStyle(tokens.secondaryText)
                                    .frame(width: 28, height: 28)
                            }
                            .accessibilityLabel("选择 Base")
                        }
                    }
                    TextField("分支", text: $branch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let message = branchErrorMessage, !message.isEmpty {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(size: 13, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }

                if let message = sessionStore.errorMessage, !message.isEmpty {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(size: 13, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            .navigationTitle("新建 Git Worktree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            let opened = await sessionStore.createWorktreeAndOpen(
                                project: project,
                                name: normalizedOptional(name),
                                base: normalizedOptional(base),
                                branch: normalizedOptional(branch)
                            )
                            if opened {
                                dismiss()
                            }
                        }
                    } label: {
                        if sessionStore.isCreatingWorktree {
                            ProgressView()
                        } else {
                            Text("创建")
                        }
                    }
                    .disabled(!canCreate)
                }
            }
            .task(id: project.path) {
                await sessionStore.refreshWorktreeBranches(path: project.path)
                applyDefaultBaseIfNeeded()
            }
            .onChange(of: branchList?.defaultBase ?? "") { _, _ in
                applyDefaultBaseIfNeeded()
            }
        }
    }

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func applyDefaultBaseIfNeeded() {
        guard !didApplyDefaultBase,
              normalizedOptional(base) == nil,
              let defaultBase = branchList?.defaultBase,
              !defaultBase.isEmpty
        else {
            return
        }
        base = defaultBase
        didApplyDefaultBase = true
    }

    private func branchMenuTitle(_ item: WorktreeBranchItem) -> String {
        if item.isCurrent {
            return "\(item.name) · 当前"
        }
        if item.isDefault {
            return "\(item.name) · 默认"
        }
        return item.name
    }

    private func branchIconName(_ item: WorktreeBranchItem) -> String {
        item.kind == "remote" ? "arrow.down.circle" : "point.topleft.down.curvedto.point.bottomright.up"
    }
}

private struct WorktreeManagerRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    let item: WorktreeListItem
    let isRunning: Bool
    let isBusy: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(tokens.accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.workspace.name)
                        .font(themeStore.uiFont(size: 15, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(1)
                    Text(item.worktree.rootProjectName)
                        .font(themeStore.uiFont(size: 12, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isRunning {
                    Text("运行中")
                        .font(themeStore.uiFont(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.success)
                }
            }

            Text(item.workspace.path)
                .font(themeStore.uiFont(size: 12, weight: .regular))
                .foregroundStyle(tokens.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(item.worktree.branch ?? item.worktree.base, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(themeStore.uiFont(size: 11, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                    Label("base \(item.worktree.base)", systemImage: "arrow.triangle.branch")
                        .font(themeStore.uiFont(size: 11, weight: .regular))
                        .foregroundStyle(tokens.tertiaryText)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: onOpen) {
                    Label("打开", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(isRunning || isBusy)
            }

            if !worktreeStatusItems.isEmpty {
                HStack(spacing: 6) {
                    ForEach(worktreeStatusItems, id: \.self) { item in
                        Text(item)
                            .font(themeStore.uiFont(size: 10, weight: .semibold))
                            .foregroundStyle(tokens.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(tokens.surface, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var worktreeStatusItems: [String] {
        var items: [String] = []
        if item.worktree.dirty {
            items.append("未提交")
        }
        if item.worktree.ahead > 0 {
            items.append("领先 \(item.worktree.ahead)")
        }
        if item.worktree.behind > 0 {
            items.append("落后 \(item.worktree.behind)")
        }
        if let upstream = item.worktree.upstream?.trimmingCharacters(in: .whitespacesAndNewlines), !upstream.isEmpty {
            items.append(upstream)
        }
        return items
    }
}

private struct SidebarListRowStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

private extension View {
    func sidebarListRow() -> some View {
        modifier(SidebarListRowStyle())
    }
}
