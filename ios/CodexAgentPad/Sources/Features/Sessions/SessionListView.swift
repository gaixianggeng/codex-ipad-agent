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
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
                Text(session.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(2)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                StatusPill(text: statusText, kind: statusKind)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let preview = session.preview, !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Text(sourceText)
                Spacer()
                if let updatedAt = session.updatedAt {
                    Text(updatedAt, style: .relative)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !metricChips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(metricChips, id: \.text) { chip in
                        Label(chip.text, systemImage: chip.symbol)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(chip.tint.opacity(0.12), in: Capsule())
                            .foregroundStyle(chip.tint)
                    }
                }
            }
        }
        .padding(.vertical, 6)
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
        case "codex":
            return session.isRunning ? "Codex app-server" : "Codex 历史"
        case "local":
            return "本地回显"
        default:
            return "PTY fallback"
        }
    }

    private var metricChips: [(text: String, symbol: String, tint: Color)] {
        var chips: [(text: String, symbol: String, tint: Color)] = []
        if session.activeTurnID != nil {
            chips.append(("active turn", "bolt.fill", .green))
        }
        if let approval = session.pendingApproval {
            chips.append(("审批 \(approval.title)", "checkmark.seal", .orange))
        }
        if let usage = session.usage?.compactText {
            chips.append((usage, "gauge.with.dots.needle.33percent", .secondary))
        }
        if let rateLimit = session.rateLimit?.compactText {
            chips.append((rateLimit, "speedometer", .secondary))
        }
        return chips
    }
}
