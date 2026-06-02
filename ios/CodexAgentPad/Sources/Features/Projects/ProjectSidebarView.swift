import SwiftUI

struct ProjectSidebarView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    var body: some View {
        List {
            Section {
                ForEach(sessionStore.projects) { project in
                    let snapshot = sessionStore.sessionListSnapshot(forProjectID: project.id)

                    ProjectRow(
                        project: project,
                        isSelected: project.id == sessionStore.selectedProjectID,
                        isExpanded: snapshot.isExpanded,
                        onToggle: {
                            Task { await sessionStore.toggleProjectExpansion(project) }
                        },
                        onNewSession: {
                            Task { await sessionStore.startNewSession(in: project) }
                        }
                    )
                    .sidebarListRow()

                    if snapshot.isExpanded {
                        ProjectSessionRows(project: project, snapshot: snapshot)
                    }
                }
            } header: {
                HStack {
                    Text("项目")
                        .foregroundStyle(SidebarTheme.headerText)
                    Spacer()
                    Button {
                        Task { await sessionStore.refreshAll(autoAttach: false) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .listStyle(.sidebar)
        .contentMargins(.top, 6, for: .scrollContent)
        .contentMargins(.bottom, 12, for: .scrollContent)
        .overlay {
            if sessionStore.projects.isEmpty && !sessionStore.isLoading {
                ContentUnavailableView("没有项目", systemImage: "folder", description: Text("请检查 agentd 的 AGENTD_SCAN_ROOTS 或配置文件。"))
            }
        }
    }
}

private struct ProjectSessionRows: View {
    @EnvironmentObject private var sessionStore: SessionStore
    let project: AgentProject
    let snapshot: ProjectSessionListSnapshot

    var body: some View {
        if snapshot.isEmpty && !sessionStore.isLoading {
            Text("暂无历史会话")
                .font(.caption)
                .foregroundStyle(SidebarTheme.mutedText)
                .padding(.leading, 28)
                .padding(.vertical, 6)
                .sidebarListRow()
        }

        ForEach(snapshot.visibleSessions) { session in
            SessionRow(session: session, isSelected: session.id == sessionStore.selectedSessionID)
                // List 行内的 Button 会被 UICollectionView 的 delaysContentTouches 拖慢高亮，
                // 改用 contentShape + onTapGesture，让点击在抬手时立即响应。
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await sessionStore.selectSession(session) }
                }
                .padding(.leading, 28)
                .sidebarListRow()
        }

        if snapshot.shouldShowActionRow {
            Text(snapshot.actionTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(SidebarTheme.mutedText)
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
                .padding(.leading, 38)
                .padding(.vertical, 5)
                .sidebarListRow()
        }
    }
}

private struct ProjectRow: View {
    let project: AgentProject
    let isSelected: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    let onNewSession: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // 整块左侧区域作为展开/收起的点击目标。用 onTapGesture 绕开 List 行内 Button
            // 在 UICollectionView 下的 delaysContentTouches 高亮延迟。
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "folder.fill" : "folder")
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? SidebarTheme.primaryText : SidebarTheme.icon)
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.headline)
                        .foregroundStyle(SidebarTheme.primaryText)
                        .lineLimit(1)
                    Text(project.path)
                        .font(.caption)
                        .foregroundStyle(SidebarTheme.secondaryText)
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SidebarTheme.mutedText)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            Image(systemName: "square.and.pencil")
                .font(.body.weight(.medium))
                .foregroundStyle(SidebarTheme.primaryText.opacity(0.86))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .onTapGesture(perform: onNewSession)
                .accessibilityLabel("新建会话")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            SidebarSelectionBackground(isSelected: isSelected, tint: SidebarTheme.projectSelectionFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? SidebarTheme.selectionStroke : Color.clear, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? SidebarTheme.primaryText : SidebarTheme.secondaryText)
                    .lineLimit(2)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                StatusPill(text: statusText, kind: statusKind)
                    .fixedSize(horizontal: true, vertical: false)
            }
            HStack {
                Text(session.source == "codex" ? "Codex" : "agentd")
                Spacer()
                if let updatedAt = session.updatedAt {
                    Text(updatedAt, style: .relative)
                }
            }
            .font(.caption)
            .foregroundStyle(SidebarTheme.mutedText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            SidebarSelectionBackground(isSelected: isSelected, tint: SidebarTheme.sessionSelectionFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? SidebarTheme.selectionStroke : Color.clear, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var statusText: String {
        session.displayStatusText
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
}

private enum SidebarTheme {
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let mutedText = Color.secondary
    static let headerText = Color.secondary
    static let icon = Color.secondary
    static let selectionStroke = Color.accentColor.opacity(0.45)
    static let projectSelectionFill = Color.accentColor.opacity(0.14)
    static let sessionSelectionFill = Color.accentColor.opacity(0.14)
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
