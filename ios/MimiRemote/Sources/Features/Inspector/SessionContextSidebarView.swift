import SwiftUI

struct SessionContextSidebarView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var contextStore: SessionContextStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var context: SessionContextSnapshot? {
        contextStore.context(for: sessionStore.selectedSessionID) ?? sessionStore.selectedSession?.context
    }

    var body: some View {
        Group {
            if let context {
                List {
                    overviewSection(context, session: sessionStore.selectedSession)
                    taskSection(context.tasks)
                    entrySection(context.sources)
                    subagentSection(context.subagents)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView("未选择会话", systemImage: "sidebar.right")
                    .font(themeStore.uiFont(.caption))
            }
        }
        .background(themeStore.tokens(for: colorScheme).surface)
    }

    private func overviewSection(_ context: SessionContextSnapshot, session: AgentSession?) -> some View {
        Section("状态") {
            if let session {
                ContextValueRow(
                    symbolName: "circle.dashed",
                    title: "状态",
                    value: session.displayStatusText
                )
                ContextValueRow(
                    symbolName: "dot.radiowaves.left.and.right",
                    title: "连接",
                    value: sessionStore.webSocketStatus.title
                )
                ContextValueRow(
                    symbolName: "folder",
                    title: "项目",
                    value: session.project.isEmpty ? session.projectID : session.project
                )
                if let activeTurnID = session.activeTurnID {
                    ContextValueRow(symbolName: "bolt.fill", title: "Turn", value: activeTurnID)
                }
                if let lastSeq = session.lastSeq {
                    ContextValueRow(symbolName: "number", title: "Seq", value: String(lastSeq))
                }
                if let revision = session.revision {
                    ContextValueRow(symbolName: "arrow.triangle.2.circlepath", title: "Rev", value: String(revision))
                }
                if let usage = session.usage?.compactText {
                    ContextValueRow(symbolName: "gauge.with.dots.needle.33percent", title: "Token", value: usage)
                }
                if let rateLimit = session.rateLimit?.compactText {
                    ContextValueRow(symbolName: "speedometer", title: "限额", value: rateLimit)
                }
            } else if let status = context.status {
                ContextValueRow(
                    symbolName: symbolName(forStatus: status),
                    title: "状态",
                    value: statusText(status)
                )
            }
            if let environment = context.environment {
                ContextValueRow(
                    symbolName: "laptopcomputer",
                    title: environment.label ?? environment.kind ?? "环境",
                    value: nonEmpty(environment.provider, environment.kind) ?? "-"
                )
                if let cwd = nonEmpty(environment.cwd) {
                    ContextValueRow(symbolName: "folder", title: "路径", value: cwd)
                }
            }
            if let git = context.git {
                if let branch = nonEmpty(git.branch) {
                    ContextValueRow(symbolName: "point.3.connected.trianglepath.dotted", title: "分支", value: branch)
                }
                if let sha = nonEmpty(git.sha) {
                    ContextValueRow(symbolName: "number", title: "提交", value: String(sha.prefix(12)))
                }
            }
            if let threadID = nonEmpty(context.threadID) {
                ContextValueRow(symbolName: "bubble.left.and.bubble.right", title: "Thread", value: threadID)
            }
        }
    }

    private func taskSection(_ tasks: [SessionContextTask]) -> some View {
        Section("任务") {
            if tasks.isEmpty {
                ContextEmptyRow(title: "暂无任务")
            } else {
                ForEach(tasks) { task in
                    ContextItemRow(
                        symbolName: symbolName(forTaskKind: task.kind),
                        title: task.title,
                        subtitle: task.subtitle,
                        badge: task.status
                    )
                }
            }
        }
    }

    private func entrySection(_ sources: [SessionContextSource]) -> some View {
        Section("入口") {
            ContextItemRow(
                symbolName: "ipad",
                title: "当前入口",
                subtitle: "Codex iPad",
                badge: nil
            )
            ForEach(sources) { source in
                ContextItemRow(
                    symbolName: symbolName(forSourceKind: source.kind),
                    title: title(forSource: source),
                    subtitle: subtitle(forSource: source),
                    badge: nil
                )
            }
        }
    }

    private func subagentSection(_ subagents: [SessionContextSubagent]) -> some View {
        Section("子 Agent") {
            if subagents.isEmpty {
                ContextEmptyRow(title: "暂无子 Agent")
            } else {
                ForEach(subagents) { subagent in
                    ContextItemRow(
                        symbolName: "person.2",
                        title: subagent.displayName,
                        subtitle: subagent.role,
                        badge: subagent.status.map(statusText)
                    )
                }
            }
        }
    }

    private func statusText(_ status: SessionContextStatus) -> String {
        var parts = [statusText(status.type)]
        if status.activeFlags.contains("waitingOnApproval") {
            parts.append("待审批")
        }
        if status.activeFlags.contains("waitingOnUserInput") {
            parts.append("待输入")
        }
        return parts.joined(separator: " · ")
    }

    private func statusText(_ status: String) -> String {
        switch status {
        case "active", "running":
            return "运行中"
        case "idle":
            return "空闲"
        case "notLoaded", "history":
            return "历史"
        case "systemError", "failed":
            return "异常"
        case "waiting_for_approval":
            return "待审批"
        case "waiting_for_input":
            return "待输入"
        case "closed":
            return "已结束"
        default:
            return status.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func symbolName(forStatus status: SessionContextStatus) -> String {
        if status.activeFlags.contains("waitingOnApproval") {
            return "checkmark.seal"
        }
        if status.activeFlags.contains("waitingOnUserInput") {
            return "keyboard"
        }
        switch status.type {
        case "active":
            return "dot.radiowaves.left.and.right"
        case "systemError":
            return "exclamationmark.triangle"
        default:
            return "circle.dashed"
        }
    }

    private func symbolName(forTaskKind kind: String) -> String {
        switch kind {
        case "command":
            return "terminal"
        case "file_change":
            return "doc.text.magnifyingglass"
        case "tool", "mcp_tool", "dynamic_tool":
            return "wrench.and.screwdriver"
        case "subagent":
            return "person.2"
        case "web_search":
            return "magnifyingglass"
        default:
            return "smallcircle.filled.circle"
        }
    }

    private func symbolName(forSourceKind kind: String) -> String {
        switch kind {
        case "session":
            return "server.rack"
        case "fork":
            return "arrow.triangle.branch"
        case "project":
            return "folder"
        case "thread":
            return "bubble.left.and.bubble.right"
        default:
            return "link"
        }
    }

    private func title(forSource source: SessionContextSource) -> String {
        switch source.kind {
        case "session":
            return "原始来源"
        case "thread":
            return "线程来源"
        case "fork":
            return "Fork 来源"
        case "project":
            return "项目"
        default:
            return source.subtitle ?? "来源"
        }
    }

    private func subtitle(forSource source: SessionContextSource) -> String? {
        switch source.kind {
        case "session", "thread":
            return displaySourceLabel(source.label)
        case "project":
            if let subtitle = nonEmpty(source.subtitle) {
                return "\(source.label) · \(subtitle)"
            }
            return source.label
        default:
            return nonEmpty(source.subtitle, displaySourceLabel(source.label))
        }
    }

    private func displaySourceLabel(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "vscode", "vs code":
            return "VS Code"
        case "cli":
            return "CLI"
        case "appserver", "app-server", "codex app-server":
            return "Codex app-server"
        case "ipad", "ios":
            return "Codex iPad"
        case "user":
            return "用户发起"
        default:
            return raw
        }
    }

    private func nonEmpty(_ values: String?...) -> String? {
        for value in values {
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }
}

private struct ContextValueRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let symbolName: String
    let title: String
    let value: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalRow
            verticalRow
        }
        .padding(.vertical, 2)
    }

    private var horizontalRow: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            rowIcon(tokens: tokens)
            Text(title)
                .font(themeStore.uiFont(.caption, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
                .frame(width: 58, alignment: .leading)
            valueText(tokens: tokens)
        }
    }

    private var verticalRow: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return HStack(alignment: .top, spacing: 10) {
            rowIcon(tokens: tokens)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(themeStore.uiFont(.caption, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                valueText(tokens: tokens)
            }
        }
    }

    private func rowIcon(tokens: ThemeTokens) -> some View {
        Image(systemName: symbolName)
            .font(themeStore.uiFont(.caption, weight: .semibold))
            .foregroundStyle(tokens.secondaryText)
            .frame(width: 18)
    }

    private func valueText(tokens: ThemeTokens) -> some View {
        Text(value)
            .font(themeStore.codeFont(.caption))
            .foregroundStyle(tokens.primaryText)
            .lineLimit(3)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ContextItemRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let symbolName: String
    let title: String
    let subtitle: String?
    let badge: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalRow
            verticalRow
        }
        .padding(.vertical, 3)
    }

    private var horizontalRow: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return HStack(alignment: .top, spacing: 10) {
            rowIcon(tokens: tokens)
            titleStack(tokens: tokens)
            if let badge, !badge.isEmpty {
                badgeText(badge, tokens: tokens)
            }
        }
    }

    private var verticalRow: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return HStack(alignment: .top, spacing: 10) {
            rowIcon(tokens: tokens)
            VStack(alignment: .leading, spacing: 4) {
                titleStack(tokens: tokens)
                if let badge, !badge.isEmpty {
                    badgeText(badge, tokens: tokens)
                }
            }
        }
    }

    private func rowIcon(tokens: ThemeTokens) -> some View {
        Image(systemName: symbolName)
            .font(themeStore.uiFont(.caption, weight: .semibold))
            .foregroundStyle(tokens.secondaryText)
            .frame(width: 18, height: 20)
    }

    private func titleStack(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.isEmpty ? "-" : title)
                .font(themeStore.uiFont(.caption, weight: .medium))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(2)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(themeStore.codeFont(.caption2))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func badgeText(_ badge: String, tokens: ThemeTokens) -> some View {
        Text(badge)
            .font(themeStore.uiFont(.caption2, weight: .medium))
            .foregroundStyle(tokens.secondaryText)
            .lineLimit(1)
    }
}

private struct ContextEmptyRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let title: String

    var body: some View {
        Label(title, systemImage: "minus.circle")
            .font(themeStore.uiFont(.caption))
            .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
    }
}
