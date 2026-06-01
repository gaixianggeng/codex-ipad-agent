import SwiftUI

struct ProjectSidebarView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    var body: some View {
        List {
            Section {
                ForEach(sessionStore.projects) { project in
                    ProjectRow(
                        project: project,
                        isSelected: project.id == sessionStore.selectedProjectID,
                        isExpanded: sessionStore.isProjectExpanded(project.id),
                        onToggle: {
                            Task { await sessionStore.toggleProjectExpansion(project) }
                        },
                        onNewSession: {
                            Task { await sessionStore.startNewSession(in: project) }
                        }
                    )

                    if sessionStore.isProjectExpanded(project.id) {
                        ProjectSessionRows(project: project)
                    }
                }
            } header: {
                HStack {
                    Text("项目")
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

    var body: some View {
        let sessions = sessionStore.visibleSessions(forProjectID: project.id)
        let allSessions = sessionStore.sessions(forProjectID: project.id)
        let hiddenCount = sessionStore.hiddenSessionCount(forProjectID: project.id)
        let isShowingAll = sessionStore.isShowingAllSessions(projectID: project.id)

        if allSessions.isEmpty && !sessionStore.isLoading {
            Text("暂无历史会话")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 28)
                .padding(.vertical, 6)
        }

        ForEach(sessions) { session in
            Button {
                Task { await sessionStore.selectSession(session) }
            } label: {
                SessionRow(session: session, isSelected: session.id == sessionStore.selectedSessionID)
            }
            .buttonStyle(.plain)
            .padding(.leading, 28)
        }

        if hiddenCount > 0 || isShowingAll && allSessions.count > SessionStore.sessionPreviewLimit {
            Button {
                sessionStore.toggleSessionListExpansion(projectID: project.id)
            } label: {
                Text(isShowingAll ? "收起显示" : "展开显示")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 38)
            .padding(.vertical, 5)
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
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "folder.fill" : "folder")
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(project.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Button(action: onNewSession) {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("新建会话")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? Color.secondary.opacity(0.10) : Color.clear)
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
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
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
