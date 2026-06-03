import SwiftUI

struct SessionContextSidebarView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var contextStore: SessionContextStore

    private var context: SessionContextSnapshot? {
        contextStore.context(for: sessionStore.selectedSessionID) ?? sessionStore.selectedSession?.context
    }

    var body: some View {
        Group {
            if let context {
                List {
                    environmentSection(context)
                    taskSection(context.tasks)
                    sourceSection(context.sources)
                    subagentSection(context.subagents)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView("未选择会话", systemImage: "sidebar.right")
                    .font(.caption)
            }
        }
        .background(Color(.secondarySystemBackground))
    }

    private func environmentSection(_ context: SessionContextSnapshot) -> some View {
        Section("环境信息") {
            if let status = context.status {
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

    private func sourceSection(_ sources: [SessionContextSource]) -> some View {
        Section("来源") {
            if sources.isEmpty {
                ContextEmptyRow(title: "暂无来源")
            } else {
                ForEach(sources) { source in
                    ContextItemRow(
                        symbolName: symbolName(forSourceKind: source.kind),
                        title: source.label,
                        subtitle: source.subtitle,
                        badge: nil
                    )
                }
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
        case "tool":
            return "wrench.and.screwdriver"
        default:
            return "smallcircle.filled.circle"
        }
    }

    private func symbolName(forSourceKind kind: String) -> String {
        switch kind {
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
    let symbolName: String
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

private struct ContextItemRow: View {
    let symbolName: String
    let title: String
    let subtitle: String?
    let badge: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title.isEmpty ? "-" : title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let badge, !badge.isEmpty {
                Text(badge)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ContextEmptyRow: View {
    let title: String

    var body: some View {
        Label(title, systemImage: "minus.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
