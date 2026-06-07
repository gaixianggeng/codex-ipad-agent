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
                ContentUnavailableView("打开路径", systemImage: "folder.badge.plus", description: Text("选择一个 Mac 工作目录后，这里只保留当前设备打开过的项目。"))
            }
        }
    }
}

private struct OpenWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var path = ""
    @State private var isOpening = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("/Users/me/code/project", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await open(path: path) }
                    } label: {
                        Label("打开路径", systemImage: "folder.badge.plus")
                    }
                    .disabled(isOpening || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Mac 路径")
                }

                Section {
                    if sessionStore.projects.isEmpty {
                        Text("没有可用候选")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sessionStore.projects) { project in
                            Button {
                                Task { await open(project: project) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(project.name)
                                    Text(project.path)
                                        .font(themeStore.uiFont(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .disabled(isOpening)
                        }
                    }
                } header: {
                    Text("候选目录")
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
        }
    }

    private func open(project: AgentProject) async {
        await open(path: project.path)
    }

    private func open(path: String) async {
        isOpening = true
        defer { isOpening = false }
        if await sessionStore.openWorkspace(path: path) {
            dismiss()
        }
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
