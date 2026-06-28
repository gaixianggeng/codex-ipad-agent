import SwiftUI

struct SessionListView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

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
                        SessionListRow(
                            session: session,
                            foregroundActivity: sessionStore.foregroundActivity(for: session.id),
                            isSelected: session.id == sessionStore.selectedSessionID
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            Task { await sessionStore.handoffSessionToWorktree(session) }
                        } label: {
                            Label("转到新 Git Worktree", systemImage: "arrow.triangle.branch")
                        }
                        .disabled(session.isRunning || sessionStore.isCreatingWorktree)
                    }
                }
            } header: {
                HStack {
                    Text(sessionStore.selectedProject?.name ?? "会话")
                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.tertiaryText)
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
        .scrollContentBackground(.hidden)
        .background(tokens.background)
        .overlay {
            if sessionStore.filteredSessions.isEmpty && !sessionStore.isLoading {
                ContentUnavailableView(
                    "没有历史会话",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("该项目暂无可继续的会话历史。")
                )
            }
        }
        .refreshable {
            await sessionStore.refreshSelectedProjectSessions()
        }
    }
}

private struct SessionListRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let session: AgentSession
    let foregroundActivity: SessionForegroundActivity?
    let isSelected: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
                Text(session.title)
                    .font(themeStore.uiFont(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(2)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                StatusPill(text: statusSummary.title, kind: statusKind)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let preview = session.preview, !preview.isEmpty {
                Text(preview)
                    .font(themeStore.uiFont(size: 12))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(2)
            }

            HStack {
                Text(sourceText)
                Spacer()
                if let updatedAt = session.updatedAt {
                    Text(updatedAt, style: .relative)
                }
            }
            .font(themeStore.uiFont(size: 12))
            .foregroundStyle(tokens.tertiaryText)

            if !metricChips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(metricChips) { chip in
                        Label(chip.title, systemImage: chip.systemImage)
                            .font(themeStore.uiFont(size: 11, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(tint(for: chip.tone).opacity(0.12), in: Capsule())
                            .foregroundStyle(tint(for: chip.tone))
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isSelected ? tokens.selectionFill : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? tokens.accent.opacity(0.45) : Color.clear, lineWidth: 1)
        }
    }

    private var statusSummary: AgentSessionDisplayStatus {
        session.displayStatus(foregroundActivity: foregroundActivity)
    }

    private var statusKind: StatusPill.Kind {
        switch statusSummary.tone {
        case .active, .complete:
            return .success
        case .warning, .danger:
            return .warning
        case .neutral:
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

    private var sourceText: String {
        switch session.source {
        case "local":
            return "本地回显"
        default:
            return session.isRunning ? "app-server" : "会话历史"
        }
    }

    private var metricChips: [AgentSessionStatusBadge] {
        session.statusBadges(foregroundActivity: foregroundActivity)
    }

    private func tint(for tone: AgentSessionStatusTone) -> Color {
        switch tone {
        case .active:
            return .green
        case .warning:
            return .orange
        case .danger:
            return .red
        case .complete:
            return .blue
        case .neutral:
            return .secondary
        }
    }
}
