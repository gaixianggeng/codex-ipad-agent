import SwiftUI

struct SessionListView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    var body: some View {
        List {
            Section {
                Button {
                    Task { await sessionStore.startNewSession() }
                } label: {
                    Label("新建会话", systemImage: "plus.circle")
                }

                ForEach(sessionStore.filteredSessions) { session in
                    Button {
                        Task { await sessionStore.selectSession(session) }
                    } label: {
                        SessionListRow(session: session, isSelected: session.id == sessionStore.selectedSessionID)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text(sessionStore.selectedProject?.name ?? "会话")
                    Spacer()
                    Button {
                        Task { await sessionStore.refreshSelectedProjectSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .overlay {
            if sessionStore.filteredSessions.isEmpty && !sessionStore.isLoading {
                ContentUnavailableView(
                    "没有历史会话",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("该项目暂无可继续的 Codex 历史。")
                )
            }
        }
        .refreshable {
            await sessionStore.refreshSelectedProjectSessions()
        }
    }
}

private struct SessionListRow: View {
    let session: AgentSession
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(2)
                Spacer(minLength: 8)
                StatusPill(text: statusText, kind: session.status == "running" ? .success : .neutral)
            }

            if let preview = session.preview, !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Text(session.source == "codex" ? "Codex 历史" : "agentd")
                Spacer()
                if let updatedAt = session.updatedAt {
                    Text(updatedAt, style: .relative)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var statusText: String {
        switch session.status {
        case "running":
            return "运行中"
        case "history":
            return "历史"
        default:
            return session.status
        }
    }
}
