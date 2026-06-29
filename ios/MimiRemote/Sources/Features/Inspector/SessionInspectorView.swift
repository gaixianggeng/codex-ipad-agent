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
                case .activity:
                    RuntimeActivityPanelView()
                case .diff:
                    DiffPanelView()
                case .approval:
                    ApprovalCardView()
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
    case activity
    case diff
    case approval

    var id: String { rawValue }

    var title: String {
        switch self {
        case .context:
            return "概览"
        case .activity:
            return "活动"
        case .diff:
            return "Git"
        case .approval:
            return "审批"
        }
    }

    var symbolName: String {
        switch self {
        case .context:
            return "sidebar.right"
        case .activity:
            return "list.bullet.rectangle"
        case .diff:
            return "doc.text.magnifyingglass"
        case .approval:
            return "checkmark.seal"
        }
    }
}

struct SessionInspectorSectionDescriptor: Equatable {
    let id: String
    let title: String
    let symbolName: String

    static var all: [SessionInspectorSectionDescriptor] {
        SessionInspectorSection.allCases.map {
            SessionInspectorSectionDescriptor(
                id: $0.id,
                title: $0.title,
                symbolName: $0.symbolName
            )
        }
    }
}

private enum RuntimeActivityMode: String, CaseIterable, Identifiable {
    case entries
    case output

    var id: String { rawValue }

    var title: String {
        switch self {
        case .entries:
            return "条目"
        case .output:
            return "原始输出"
        }
    }
}

private struct RuntimeActivityPanelView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var conversationStore: ConversationStore
    @EnvironmentObject private var logStore: LogStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedMode: RuntimeActivityMode = .entries

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(spacing: 0) {
            Picker("活动", selection: $selectedMode) {
                ForEach(RuntimeActivityMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)

            Rectangle()
                .fill(tokens.border)
                .frame(height: 1)

            Group {
                switch selectedMode {
                case .entries:
                    entriesContent(tokens: tokens)
                case .output:
                    outputContent(tokens: tokens)
                }
            }
        }
        .background(tokens.surface)
    }

    private func entriesContent(tokens: ThemeTokens) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if runtimeMessages.isEmpty {
                    ContentUnavailableView("暂无活动条目", systemImage: "list.bullet.rectangle")
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

    private func outputContent(tokens: ThemeTokens) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Toggle("自动滚动", isOn: $logStore.autoScroll)
                    .toggleStyle(.switch)
                    .font(themeStore.uiFont(.caption))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tokens.surface)

            Rectangle()
                .fill(tokens.border)
                .frame(height: 1)

            LogTailContentView()
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
        case .userInput:
            return "补充信息"
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
        case .userInput:
            return "questionmark.bubble"
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
        case .userInput:
            return tokens.accent
        case .error:
            return .red
        case .fileChangeSummary:
            return tokens.accent
        default:
            return tokens.secondaryText
        }
    }
}
