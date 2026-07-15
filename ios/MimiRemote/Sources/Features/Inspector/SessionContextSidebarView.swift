import SwiftUI

struct SessionContextSidebarView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var contextStore: SessionContextStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var pendingCommandAction: AgentCommandAction?
    @State private var goalEditor: ThreadGoalEditorDraft?

    private var context: SessionContextSnapshot? {
        contextStore.context(for: sessionStore.selectedSessionID) ?? sessionStore.selectedSession?.context
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if let context {
                List {
                    overviewSection(context, session: sessionStore.selectedSession)
                    goalSection(goal: sessionStore.selectedThreadGoal ?? context.goal)
                    commandActionSection()
                    taskSection(context.tasks)
                    entrySection(context.sources)
                    subagentSection(context.subagents)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 8, for: .scrollContent)
                .contentMargins(.bottom, 12, for: .scrollContent)
                .background(tokens.sidebarBackground)
                .task(id: sessionStore.selectedCommandActionPath) {
                    await sessionStore.refreshSelectedCommandActions()
                }
            } else {
                ContentUnavailableView("未选择会话", systemImage: "sidebar.right")
                    .font(themeStore.uiFont(.caption))
            }
        }
        .background(tokens.sidebarBackground)
        .sheet(item: $goalEditor) { draft in
            ThreadGoalEditorSheet(draft: draft)
        }
        .confirmationDialog("执行这个动作？", isPresented: Binding(
            get: { pendingCommandAction != nil },
            set: { isPresented in
                if !isPresented {
                    pendingCommandAction = nil
                }
            }
        ), titleVisibility: .visible) {
            if let action = pendingCommandAction {
                Button("执行 \(action.name)", role: .destructive) {
                    let target = action
                    pendingCommandAction = nil
                    Task { await sessionStore.runSelectedCommandAction(target) }
                }
            }
            Button("取消", role: .cancel) {
                pendingCommandAction = nil
            }
        } message: {
            if let action = pendingCommandAction {
                Text("\(action.displayCommand)\n\(action.workingDir)")
            }
        }
    }

    private var currentDeviceSymbolName: String {
        horizontalSizeClass == .compact ? "iphone" : "ipad"
    }

    @ViewBuilder
    private func goalSection(goal: ThreadGoal?) -> some View {
        Section("目标") {
            if let goal {
                ContextItemRow(
                    symbolName: "target",
                    title: goal.objective,
                    subtitle: goal.progressText,
                    badge: goal.status.displayText
                )
                if goal.timeUsedSeconds > 0 {
                    ContextValueRow(symbolName: "timer", title: "耗时", value: goal.elapsedText)
                }
                if let updatedAt = goal.updatedAt {
                    ContextValueRow(symbolName: "clock", title: "更新", value: updatedAt.formatted(date: .omitted, time: .shortened))
                }
                Button {
                    goalEditor = ThreadGoalEditorDraft(sessionID: goal.threadID, existing: goal)
                } label: {
                    Label("编辑目标", systemImage: "pencil")
                }
                .disabled(sessionStore.isUpdatingThreadGoal)

                ForEach(goalStatusActions(for: goal), id: \.status) { action in
                    Button {
                        Task { await sessionStore.updateSelectedThreadGoalStatus(action.status) }
                    } label: {
                        Label(action.title, systemImage: action.symbolName)
                    }
                    .disabled(sessionStore.isUpdatingThreadGoal)
                }

                Button(role: .destructive) {
                    Task { await sessionStore.clearSelectedThreadGoal() }
                } label: {
                    Label("清除目标", systemImage: "trash")
                }
                .disabled(sessionStore.isUpdatingThreadGoal)
            } else {
                ContextEmptyRow(title: "暂无目标")
            }

            Button {
                Task { await sessionStore.refreshSelectedThreadGoal() }
            } label: {
                Label("刷新目标", systemImage: "arrow.clockwise")
            }
            .disabled(sessionStore.selectedSessionID == nil || sessionStore.isUpdatingThreadGoal)

            if sessionStore.isUpdatingThreadGoal {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在同步目标")
                        .font(themeStore.uiFont(.caption))
                }
                .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
            }
            if let error = sessionStore.threadGoalErrorMessage {
                ContextItemRow(
                    symbolName: "exclamationmark.triangle",
                    title: "目标同步失败",
                    subtitle: error,
                    badge: nil
                )
            }
        }
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

    @ViewBuilder
    private func commandActionSection() -> some View {
        Section("动作") {
            if sessionStore.selectedCommandActionPath == nil {
                ContextEmptyRow(title: "未选择工作区")
            } else {
                if let error = sessionStore.selectedCommandActionErrorMessage {
                    ContextItemRow(
                        symbolName: "exclamationmark.triangle",
                        title: "动作不可用",
                        subtitle: error,
                        badge: nil
                    )
                }
                if sessionStore.isRefreshingCommandActions && sessionStore.selectedCommandActions.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在读取动作")
                            .font(themeStore.uiFont(.caption))
                    }
                    .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
                } else if sessionStore.selectedCommandActions.isEmpty {
                    ContextEmptyRow(title: "未配置快捷动作")
                } else {
                    let selectedActionPath = sessionStore.selectedCommandActionPath
                    let queuedActionIDs = sessionStore.selectedQueuedCommandActionIDs
                    ForEach(sessionStore.selectedCommandActions) { action in
                        let isRunning = sessionStore.runningCommandActionPath == selectedActionPath
                            && sessionStore.runningCommandActionID == action.id
                        CommandActionButtonRow(
                            action: action,
                            isRunning: isRunning,
                            queuedCount: queuedActionIDs.filter { $0 == action.id }.count,
                            isDisabled: isRunning
                        ) {
                            if action.requiresConfirmation {
                                pendingCommandAction = action
                            } else {
                                Task { await sessionStore.runSelectedCommandAction(action) }
                            }
                        }
                    }
                }
                let history = sessionStore.selectedCommandActionHistory
                if !history.isEmpty {
                    ContextInlineHeader(title: "最近输出")
                    ForEach(Array(history.prefix(3).enumerated()), id: \.offset) { _, result in
                        CommandActionResultRow(result: result)
                    }
                }
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
                        badge: task.status.map(statusText)
                    )
                }
            }
        }
    }

    private func entrySection(_ sources: [SessionContextSource]) -> some View {
        Section("入口") {
            ContextItemRow(
                symbolName: currentDeviceSymbolName,
                title: "当前入口",
                subtitle: "Mimi Remote",
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
        case "active", "running", "inProgress", "in_progress", "started":
            return "运行中"
        case "idle":
            return "空闲"
        case "completed", "complete", "success", "succeeded":
            return "完成"
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
        case "unknown", "":
            return "待确认"
        default:
            return status.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func goalStatusActions(for goal: ThreadGoal) -> [(status: ThreadGoalStatus, title: String, symbolName: String)] {
        switch goal.status {
        case .active:
            return [
                (.paused, "暂停目标", "pause.circle"),
                (.complete, "标记完成", "checkmark.circle"),
                (.blocked, "标记阻塞", "exclamationmark.octagon")
            ]
        case .paused, .blocked, .usageLimited, .budgetLimited:
            return [
                (.active, "继续目标", "play.circle"),
                (.complete, "标记完成", "checkmark.circle")
            ]
        case .complete:
            return [
                (.active, "重新激活", "play.circle")
            ]
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
            return "app-server"
        case "ipad", "iphone", "ios":
            return "Mimi Remote"
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

struct ThreadGoalEditorDraft: Identifiable {
    let id = UUID()
    let sessionID: SessionID
    let existing: ThreadGoal?

    var title: String {
        "编辑目标"
    }

    var objective: String {
        existing?.objective ?? ""
    }

    var tokenBudgetText: String {
        existing?.tokenBudget.map(String.init) ?? ""
    }

    var status: ThreadGoalStatus {
        existing?.status ?? .active
    }
}

struct ThreadGoalEditorSheet: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @State private var objective: String
    @State private var tokenBudgetText: String
    let draft: ThreadGoalEditorDraft

    init(draft: ThreadGoalEditorDraft) {
        self.draft = draft
        _objective = State(initialValue: draft.objective)
        _tokenBudgetText = State(initialValue: draft.tokenBudgetText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("目标") {
                    TextField("目标", text: $objective, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("Token 预算", text: $tokenBudgetText)
                        .keyboardType(.numberPad)
                }
                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(draft.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(validationMessage != nil || sessionStore.isUpdatingThreadGoal)
                }
            }
        }
    }

    private var validationMessage: String? {
        if objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "目标内容不能为空"
        }
        let budget = tokenBudgetText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !budget.isEmpty {
            guard let value = Int64(budget), value > 0 else {
                return "Token 预算必须是正整数"
            }
        }
        return nil
    }

    private var parsedTokenBudget: Int64? {
        let text = tokenBudgetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        return Int64(text)
    }

    private func save() {
        Task {
            let ok = await sessionStore.setThreadGoal(
                threadID: draft.sessionID,
                objective: objective,
                status: draft.status,
                tokenBudget: parsedTokenBudget
            )
            if ok {
                dismiss()
            }
        }
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

        return HStack(alignment: .top, spacing: 10) {
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
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tokens.secondaryText)
            .frame(width: 26, height: 26)
            .background(tokens.elevatedSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(tokens.border.opacity(0.46), lineWidth: 1)
            }
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

private struct CommandActionButtonRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let action: AgentCommandAction
    let isRunning: Bool
    let queuedCount: Int
    let isDisabled: Bool
    let onRun: () -> Void

    var body: some View {
        Button(action: onRun) {
            HStack(alignment: .top, spacing: 10) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 20)
                } else {
                    Image(systemName: queuedCount > 0 ? "clock.arrow.circlepath" : "play.circle.fill")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(queuedCount > 0 ? tokens.secondaryText : tokens.accent)
                        .frame(width: 18, height: 20)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.name)
                        .font(themeStore.uiFont(.caption, weight: .medium))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(2)
                    if queuedCount > 0 || action.requiresConfirmation {
                        HStack(spacing: 6) {
                            if queuedCount > 0 {
                                Label("排队中 · \(queuedCount)", systemImage: "clock")
                                    .foregroundStyle(tokens.secondaryText)
                            }
                            if action.requiresConfirmation {
                                Label("需确认", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(tokens.warning)
                            }
                        }
                        .font(themeStore.uiFont(.caption2, weight: .semibold))
                        .lineLimit(1)
                    }
                    Text(action.displayCommand)
                        .font(themeStore.codeFont(.caption2))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(action.workingDir)
                        .font(themeStore.codeFont(.caption2))
                        .foregroundStyle(tokens.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }
}

private struct CommandActionResultRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let result: CommandActionRunResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: result.success ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(result.success ? tokens.success : tokens.warning)
                Text(title)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Spacer(minLength: 8)
                Text("\(result.durationMS) ms")
                    .font(themeStore.codeFont(.caption2))
                    .foregroundStyle(tokens.secondaryText)
            }
            Text(result.displayCommand)
                .font(themeStore.codeFont(.caption2))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(outputText)
                .font(themeStore.codeFont(.caption2))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(10)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if result.truncated == true {
                Text("输出过长，已截断")
                    .font(themeStore.uiFont(.caption2))
                    .foregroundStyle(tokens.warning)
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        if result.timedOut == true {
            return "\(result.name) 超时"
        }
        if result.success {
            return "\(result.name) 完成"
        }
        return "\(result.name) 失败 · \(result.exitCode)"
    }

    private var outputText: String {
        let text = result.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "无输出" : text
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }
}

private struct ContextInlineHeader: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let title: String

    var body: some View {
        Text(title)
            .font(themeStore.uiFont(.caption2, weight: .semibold))
            .foregroundStyle(themeStore.tokens(for: colorScheme).tertiaryText)
            .padding(.top, 4)
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
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tokens.secondaryText)
            .frame(width: 26, height: 26)
            .background(tokens.elevatedSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(tokens.border.opacity(0.46), lineWidth: 1)
            }
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
