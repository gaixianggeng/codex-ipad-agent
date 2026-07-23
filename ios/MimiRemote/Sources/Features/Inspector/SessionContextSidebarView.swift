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
                ContentUnavailableView(L10n.text("ui.no_session_selected"), systemImage: "sidebar.right")
                    .font(themeStore.uiFont(.caption))
            }
        }
        .background(tokens.sidebarBackground)
        .sheet(item: $goalEditor) { draft in
            ThreadGoalEditorSheet(draft: draft)
        }
        .confirmationDialog(L10n.text("ui.perform_this_action"), isPresented: Binding(
            get: { pendingCommandAction != nil },
            set: { isPresented in
                if !isPresented {
                    pendingCommandAction = nil
                }
            }
        ), titleVisibility: .visible) {
            if let action = pendingCommandAction {
                Button(L10n.format("ui.execute_value", action.name), role: .destructive) {
                    let target = action
                    pendingCommandAction = nil
                    Task { await sessionStore.runSelectedCommandAction(target) }
                }
            }
            Button(L10n.text("ui.cancel"), role: .cancel) {
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
        Section(L10n.text("ui.target")) {
            if let goal {
                ContextItemRow(
                    symbolName: "target",
                    title: goal.objective,
                    subtitle: goal.progressText,
                    badge: goal.status.displayText
                )
                if goal.timeUsedSeconds > 0 {
                    ContextValueRow(symbolName: "timer", title: L10n.text("ui.time_consuming"), value: goal.elapsedText)
                }
                if let updatedAt = goal.updatedAt {
                    ContextValueRow(symbolName: "clock", title: L10n.text("ui.updated_label"), value: updatedAt.formatted(date: .omitted, time: .shortened))
                }
                Button {
                    goalEditor = ThreadGoalEditorDraft(sessionID: goal.threadID, existing: goal)
                } label: {
                    Label(L10n.text("ui.edit_target"), systemImage: "pencil")
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
                    Label(L10n.text("ui.clear_target"), systemImage: "trash")
                }
                .disabled(sessionStore.isUpdatingThreadGoal)
            } else {
                ContextEmptyRow(title: L10n.text("ui.no_target_yet"))
            }

            Button {
                Task { await sessionStore.refreshSelectedThreadGoal() }
            } label: {
                Label(L10n.text("ui.refresh_target"), systemImage: "arrow.clockwise")
            }
            .disabled(sessionStore.selectedSessionID == nil || sessionStore.isUpdatingThreadGoal)

            if sessionStore.isUpdatingThreadGoal {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("ui.synchronizing_target"))
                        .font(themeStore.uiFont(.caption))
                }
                .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
            }
            if let error = sessionStore.threadGoalErrorMessage {
                ContextItemRow(
                    symbolName: "exclamationmark.triangle",
                    title: L10n.text("ui.target_sync_failed"),
                    subtitle: error,
                    badge: nil
                )
            }
        }
    }

    private func overviewSection(_ context: SessionContextSnapshot, session: AgentSession?) -> some View {
        Section(L10n.text("ui.status")) {
            if let session {
                ContextValueRow(
                    symbolName: "circle.dashed",
                    title: L10n.text("ui.status"),
                    value: session.displayStatusText
                )
                ContextValueRow(
                    symbolName: "dot.radiowaves.left.and.right",
                    title: L10n.text("ui.connect"),
                    value: sessionStore.webSocketStatus.title
                )
                ContextValueRow(
                    symbolName: "folder",
                    title: L10n.text("ui.project"),
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
                    ContextValueRow(symbolName: "speedometer", title: L10n.text("ui.limit"), value: rateLimit)
                }
            } else if let status = context.status {
                ContextValueRow(
                    symbolName: symbolName(forStatus: status),
                    title: L10n.text("ui.status"),
                    value: statusText(status)
                )
            }
            if let environment = context.environment {
                ContextValueRow(
                    symbolName: "laptopcomputer",
                    title: environment.label ?? environment.kind ?? L10n.text("ui.environment"),
                    value: nonEmpty(environment.provider, environment.kind) ?? "-"
                )
                if let cwd = nonEmpty(environment.cwd) {
                    ContextValueRow(symbolName: "folder", title: L10n.text("ui.path"), value: cwd)
                }
            }
            if let git = context.git {
                if let branch = nonEmpty(git.branch) {
                    ContextValueRow(symbolName: "point.3.connected.trianglepath.dotted", title: L10n.text("ui.branch"), value: branch)
                }
                if let sha = nonEmpty(git.sha) {
                    ContextValueRow(symbolName: "number", title: L10n.text("ui.submit"), value: String(sha.prefix(12)))
                }
            }
            if let threadID = nonEmpty(context.threadID) {
                ContextValueRow(symbolName: "bubble.left.and.bubble.right", title: "Thread", value: threadID)
            }
        }
    }

    @ViewBuilder
    private func commandActionSection() -> some View {
        Section(L10n.text("ui.action")) {
            if sessionStore.selectedCommandActionPath == nil {
                ContextEmptyRow(title: L10n.text("ui.no_workspace_selected"))
            } else {
                if let error = sessionStore.selectedCommandActionErrorMessage {
                    ContextItemRow(
                        symbolName: "exclamationmark.triangle",
                        title: L10n.text("ui.action_not_available"),
                        subtitle: error,
                        badge: nil
                    )
                }
                if sessionStore.isRefreshingCommandActions && sessionStore.selectedCommandActions.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.text("ui.reading_action"))
                            .font(themeStore.uiFont(.caption))
                    }
                    .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
                } else if sessionStore.selectedCommandActions.isEmpty {
                    ContextEmptyRow(title: L10n.text("ui.no_quick_action_configured"))
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
                    ContextInlineHeader(title: L10n.text("ui.recent_output"))
                    ForEach(Array(history.prefix(3).enumerated()), id: \.offset) { _, result in
                        CommandActionResultRow(result: result)
                    }
                }
            }
        }
    }

    private func taskSection(_ tasks: [SessionContextTask]) -> some View {
        Section(L10n.text("ui.task")) {
            if tasks.isEmpty {
                ContextEmptyRow(title: L10n.text("ui.no_tasks_yet"))
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
        Section(L10n.text("ui.entrance")) {
            ContextItemRow(
                symbolName: currentDeviceSymbolName,
                title: L10n.text("ui.current_entrance"),
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
        Section(L10n.text("ui.sub_agent")) {
            if subagents.isEmpty {
                ContextEmptyRow(title: L10n.text("ui.no_sub_agents_yet"))
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
            parts.append(L10n.text("ui.pending_approval"))
        }
        if status.activeFlags.contains("waitingOnUserInput") {
            parts.append(L10n.text("ui.to_be_entered"))
        }
        return parts.joined(separator: " · ")
    }

    private func statusText(_ status: String) -> String {
        switch status {
        case "active", "running", "inProgress", "in_progress", "started":
            return L10n.text("ui.running")
        case "idle":
            return L10n.text("ui.free")
        case "completed", "complete", "success", "succeeded":
            return L10n.text("ui.complete")
        case "notLoaded", "history":
            return L10n.text("ui.history")
        case "systemError", "failed":
            return L10n.text("ui.abnormal")
        case "waiting_for_approval":
            return L10n.text("ui.pending_approval")
        case "waiting_for_input":
            return L10n.text("ui.to_be_entered")
        case "closed":
            return L10n.text("ui.ended")
        case "unknown", "":
            return L10n.text("ui.to_be_confirmed")
        default:
            return status.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func goalStatusActions(for goal: ThreadGoal) -> [(status: ThreadGoalStatus, title: String, symbolName: String)] {
        switch goal.status {
        case .active:
            return [
                (.paused, L10n.text("ui.pause_target"), "pause.circle"),
                (.complete, L10n.text("ui.mark_complete"), "checkmark.circle"),
                (.blocked, L10n.text("ui.mark_blocking"), "exclamationmark.octagon")
            ]
        case .paused, .blocked, .usageLimited, .budgetLimited:
            return [
                (.active, L10n.text("ui.continue_target"), "play.circle"),
                (.complete, L10n.text("ui.mark_complete"), "checkmark.circle")
            ]
        case .complete:
            return [
                (.active, L10n.text("ui.reactivate"), "play.circle")
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
            return L10n.text("ui.original_source")
        case "thread":
            return L10n.text("ui.thread_source")
        case "fork":
            return L10n.text("ui.fork_source")
        case "project":
            return L10n.text("ui.project")
        default:
            return source.subtitle ?? L10n.text("ui.source")
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
            return L10n.text("Mimi Remote")
        case "user":
            return L10n.text("ui.user_initiated")
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
        L10n.text("ui.edit_target")
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
                Section(L10n.text("ui.target")) {
                    TextField(L10n.text("ui.target"), text: $objective, axis: .vertical)
                        .lineLimit(3...6)
                    TextField(L10n.text("ui.token_budget"), text: $tokenBudgetText)
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
                    Button(L10n.text("ui.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.save")) {
                        save()
                    }
                    .disabled(validationMessage != nil || sessionStore.isUpdatingThreadGoal)
                }
            }
        }
    }

    private var validationMessage: String? {
        if objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.text("ui.target_content_cannot_be_empty")
        }
        let budget = tokenBudgetText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !budget.isEmpty {
            guard let value = Int64(budget), value > 0 else {
                return L10n.text("ui.token_budget_must_be_a_positive_integer")
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
                                Label(L10n.format("ui.queuing_value", queuedCount), systemImage: "clock")
                                    .foregroundStyle(tokens.secondaryText)
                            }
                            if action.requiresConfirmation {
                                Label(L10n.text("ui.need_to_confirm"), systemImage: "exclamationmark.triangle")
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
                Text(L10n.text("ui.the_output_is_too_long_and_has_been"))
                    .font(themeStore.uiFont(.caption2))
                    .foregroundStyle(tokens.warning)
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        if result.timedOut == true {
            return L10n.format("ui.value_timeout", result.name)
        }
        if result.success {
            return L10n.format("ui.value_complete", result.name)
        }
        return L10n.format("ui.value_failed_value", result.name, result.exitCode)
    }

    private var outputText: String {
        let text = result.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? L10n.text("ui.no_output") : text
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
