import SwiftUI

struct ProjectSidebarView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isPresentingOpenWorkspace = false
    var showsSessions = true

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let selectedProjectID = sessionStore.selectedProjectID
        let selectedSessionID = sessionStore.selectedSessionID

        List {
            Section {
                ForEach(sessionStore.sidebarProjects) { project in
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
        .sheet(isPresented: $isPresentingOpenWorkspace) {
            OpenWorkspaceSheet()
        }
        .overlay {
            if sessionStore.sidebarProjects.isEmpty && !sessionStore.isLoading {
                ContentUnavailableView {
                    Label("没有已打开的工作区", systemImage: "folder.badge.plus")
                } description: {
                    Text("选择 Mac 上已授权的工作目录后，这里会保留最近打开的项目。")
                } actions: {
                    Button {
                        isPresentingOpenWorkspace = true
                    } label: {
                        Label("打开 Mac 路径", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
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
                    Text("可直接粘贴 Mac 上的绝对路径；目录需在 Mac 端已授权范围内（默认是用户 Home）。")
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
                Text("没有可进入的子目录")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(browseEntries) { entry in
                    Button {
                        Task { await browse(to: entry.path) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
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
                            Image(systemName: "chevron.right")
                                .font(themeStore.uiFont(size: 12, weight: .semibold))
                                .foregroundStyle(tokens.tertiaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!entry.canBrowse || isOpening)
                }
            }
        } header: {
            Text("子目录")
        } footer: {
            if browseTruncated {
                Text("目录过大，仅显示前面部分；其余子目录请用下方手动输入路径。")
            } else {
                Text("隐藏目录、Library 与常见缓存目录不会显示。")
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
            return "Mac 端 agentd 版本还不支持目录浏览，请升级 agentd；也可以直接在下方输入路径。"
        }
        if case AgentAPIError.server(let status, _) = error, status == 403 {
            return "该目录不在 Mac 端授权范围内或不可访问。"
        }
        return error.localizedDescription
    }

    private func open(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            localError = "请输入 Mac 上的目录路径"
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
            return "“\(path)”还不在 Mac 端已授权范围内。默认浏览授权根是用户 Home；如改过配置，请在 Mac 上调整 browse_roots（或 AGENTD_BROWSE_ROOTS）后重试。"
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
            SessionRow(session: session, isSelected: session.id == selectedSessionID)
                .equatable()
                // List 行内的 Button 会被 UICollectionView 的 delaysContentTouches 拖慢高亮，
                // 改用 contentShape + onTapGesture，让点击在抬手时立即响应。
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await sessionStore.selectSession(session) }
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
    let isSelected: Bool

    static func == (lhs: SessionRow, rhs: SessionRow) -> Bool {
        lhs.session == rhs.session && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
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

        if session.pendingApproval != nil {
            Image(systemName: "exclamationmark.circle.fill")
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityLabel("等待审批")
        } else if session.activeTurnID != nil || session.isRunning {
            Image(systemName: "circle.dotted")
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(.green)
                .accessibilityLabel(session.displayStatusText)
        } else if let updatedAt = session.updatedAt {
            Text(updatedAt, style: .relative)
                .font(themeStore.uiFont(size: 12, weight: .medium))
                .foregroundStyle(tokens.tertiaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var statusKind: StatusPill.Kind {
        switch session.status {
        case "running":
            return .success
        case "failed", "waiting_for_approval":
            return .warning
        default:
            return .neutral
        }
    }

    private var statusDotColor: Color {
        switch statusKind {
        case .success:
            return .green
        case .warning:
            return .orange
        case .neutral:
            return .secondary.opacity(0.55)
        }
    }
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
