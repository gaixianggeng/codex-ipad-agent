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

                // 会话在创建瞬间就绑定 runtime；Claude 通道必须在入口显式选择，
                // 建好之后模型菜单只会显示所属通道的模型。
                if sessionStore.hasClaudeRuntimeChannel {
                    Button {
                        Task { await sessionStore.startNewSession(runtimeProvider: "claude") }
                    } label: {
                        Label("新建 Claude Code 会话", systemImage: "sparkles")
                    }
                }

                ForEach(sessionStore.filteredSessions) { session in
                    Button {
                        Task { await sessionStore.selectSession(session) }
                    } label: {
                        SessionListRow(
                            session: session,
                            foregroundActivity: sessionStore.foregroundActivity(for: session.id),
                            isSelected: session.id == sessionStore.selectedSessionID,
                            isObserving: sessionStore.isSessionObserving(session)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if sessionStore.isSessionObserving(session) {
                            Button {
                                sessionStore.takeOverSession(session)
                            } label: {
                                Label("接管到 iPad", systemImage: "hand.raised.fill")
                            }
                        }

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
    let isObserving: Bool

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
                    Text(Self.minuteTimeFormatter.string(from: updatedAt))
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
        if isObserving {
            return AgentSessionDisplayStatus(title: "观察中", systemImage: "eye", tone: .neutral, showsSpinner: false)
        }
        return session.displayStatus(foregroundActivity: foregroundActivity)
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
        let tokens = themeStore.tokens(for: colorScheme)
        switch statusKind {
        case .success:
            return tokens.success
        case .warning:
            return tokens.warning
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
        themeStore.tokens(for: colorScheme).tint(for: tone)
    }

    // 左侧列表只需要分钟级时间；避免 SwiftUI relative 文本按秒刷新导致整列跳动。
    private static let minuteTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
