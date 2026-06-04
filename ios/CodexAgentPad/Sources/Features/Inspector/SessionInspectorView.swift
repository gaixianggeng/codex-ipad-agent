import SwiftUI

struct SessionInspectorView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedSection: SessionInspectorSection = .context

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(spacing: 0) {
            header
            Picker("Inspector", selection: $selectedSection) {
                ForEach(SessionInspectorSection.allCases) { section in
                    Image(systemName: section.symbolName)
                        .tag(section)
                        .accessibilityLabel(section.title)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Rectangle()
                .fill(tokens.border)
                .frame(height: 1)

            Group {
                switch selectedSection {
                case .context:
                    SessionContextSidebarView()
                case .details:
                    RuntimeDetailsPanelView()
                case .logs:
                    LogTailView()
                case .diff:
                    DiffPanelView()
                case .approval:
                    ApprovalCardView()
                case .diagnostics:
                    SessionDiagnosticsPanel()
                }
            }
        }
        .background(tokens.surface)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: selectedSection.symbolName)
                .font(themeStore.uiFont(.callout, weight: .semibold))
                .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(selectedSection.title)
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(themeStore.tokens(for: colorScheme).primaryText)
                Text(sessionSubtitle)
                    .font(themeStore.codeFont(.caption2))
                    .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var sessionSubtitle: String {
        sessionStore.selectedSession?.title ?? sessionStore.selectedProject?.name ?? "未选择会话"
    }
}

private enum SessionInspectorSection: String, CaseIterable, Identifiable {
    case context
    case details
    case logs
    case diff
    case approval
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .context:
            return "状态"
        case .details:
            return "详情"
        case .logs:
            return "日志"
        case .diff:
            return "文件"
        case .approval:
            return "审批"
        case .diagnostics:
            return "诊断"
        }
    }

    var symbolName: String {
        switch self {
        case .context:
            return "sidebar.right"
        case .details:
            return "list.bullet.rectangle"
        case .logs:
            return "terminal"
        case .diff:
            return "doc.text.magnifyingglass"
        case .approval:
            return "checkmark.seal"
        case .diagnostics:
            return "stethoscope"
        }
    }
}

private struct RuntimeDetailsPanelView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var conversationStore: ConversationStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if runtimeMessages.isEmpty {
                    ContentUnavailableView("暂无运行详情", systemImage: "list.bullet.rectangle")
                        .font(themeStore.uiFont(.caption))
                        .padding(.top, 48)
                } else {
                    ForEach(runtimeMessages) { message in
                        InspectorSummaryCard(
                            symbolName: symbolName(for: message.kind),
                            title: title(for: message.kind),
                            subtitle: message.content,
                            tint: tint(for: message.kind, tokens: tokens),
                            lineLimit: nil
                        )
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var runtimeMessages: [ConversationMessage] {
        Array(
            conversationStore
                .messages(for: sessionStore.selectedSessionID)
                .filter { $0.kind != .message }
                .suffix(80)
        )
    }

    private func title(for kind: MessageKind) -> String {
        switch kind {
        case .reasoningSummary:
            return "推理摘要"
        case .commandSummary:
            return "命令 / 工具"
        case .fileChangeSummary:
            return "文件变更"
        case .approval:
            return "审批"
        case .error:
            return "运行异常"
        case .message:
            return "消息"
        }
    }

    private func symbolName(for kind: MessageKind) -> String {
        switch kind {
        case .reasoningSummary:
            return "brain.head.profile"
        case .commandSummary:
            return "terminal"
        case .fileChangeSummary:
            return "doc.text.magnifyingglass"
        case .approval:
            return "checkmark.seal"
        case .error:
            return "exclamationmark.triangle"
        case .message:
            return "info.circle"
        }
    }

    private func tint(for kind: MessageKind, tokens: ThemeTokens) -> Color {
        switch kind {
        case .approval:
            return tokens.warning
        case .error:
            return .red
        case .fileChangeSummary:
            return tokens.accent
        default:
            return tokens.secondaryText
        }
    }
}

private struct SessionDiagnosticsPanel: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let session = sessionStore.selectedSession {
                    diagnosticsCard(session)
                } else {
                    ContentUnavailableView("未选择会话", systemImage: "bubble.left.and.bubble.right")
                        .font(themeStore.uiFont(.caption))
                        .padding(.top, 48)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func diagnosticsCard(_ session: AgentSession) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return VStack(alignment: .leading, spacing: 10) {
            InspectorMetricRow(title: "状态", value: session.displayStatusText, symbolName: "circle.dashed")
            InspectorMetricRow(title: "来源", value: session.source == "codex" ? "Codex app-server" : "PTY fallback", symbolName: "server.rack")
            InspectorMetricRow(title: "实时连接", value: sessionStore.webSocketStatus.title, symbolName: "dot.radiowaves.left.and.right")
            InspectorMetricRow(title: "项目", value: session.project.isEmpty ? session.projectID : session.project, symbolName: "folder")
            InspectorMetricRow(title: "路径", value: session.dir, symbolName: "terminal")

            if let activeTurnID = session.activeTurnID {
                InspectorMetricRow(title: "Active turn", value: activeTurnID, symbolName: "bolt.fill")
            }
            if let lastSeq = session.lastSeq {
                InspectorMetricRow(title: "事件序号", value: String(lastSeq), symbolName: "number")
            }
            if let revision = session.revision {
                InspectorMetricRow(title: "Revision", value: String(revision), symbolName: "arrow.triangle.2.circlepath")
            }
            if let usage = session.usage?.compactText {
                InspectorMetricRow(title: "Token / Cost", value: usage, symbolName: "gauge.with.dots.needle.33percent")
            }
            if let rateLimit = session.rateLimit?.compactText {
                InspectorMetricRow(title: "Rate limit", value: rateLimit, symbolName: "speedometer")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.border, lineWidth: 1)
        }
    }
}

private struct InspectorMetricRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String
    let symbolName: String

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbolName)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)
                .frame(width: 16, height: 18)

            Text(title)
                .font(themeStore.uiFont(.caption, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
                .frame(width: 82, alignment: .leading)

            Text(value.isEmpty ? "-" : value)
                .font(themeStore.codeFont(.caption))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
