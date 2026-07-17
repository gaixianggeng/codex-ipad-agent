import SwiftUI

struct QueuedTurnEditorDraft: Identifiable {
    let id: ClientMessageID
    let turn: QueuedTurnEntry
    let text: String
    let attachments: [CodexAppServerUserInput]

    init(turn: QueuedTurnEntry) {
        self.id = turn.id
        self.turn = turn
        self.text = turn.payload.textPrompt
        self.attachments = turn.payload.input.filter { input in
            if case .text = input {
                return false
            }
            return true
        }
    }

    func payload(text: String, attachments: [CodexAppServerUserInput]) -> CodexAppServerTurnPayload {
        var input = CodexAppServerTurnPayload.defaultInput(for: text)
        input.append(contentsOf: attachments)
        return CodexAppServerTurnPayload(input: input, options: turn.payload.options)
    }
}

struct QueuedTurnEditorSheet: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let draft: QueuedTurnEditorDraft
    let onSave: (CodexAppServerTurnPayload) -> Void
    @State private var text: String
    @State private var attachments: [CodexAppServerUserInput]

    init(draft: QueuedTurnEditorDraft, onSave: @escaping (CodexAppServerTurnPayload) -> Void) {
        self.draft = draft
        self.onSave = onSave
        _text = State(initialValue: draft.text)
        _attachments = State(initialValue: draft.attachments)
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        NavigationStack {
            Form {
                Section("消息") {
                    TextEditor(text: $text)
                        .frame(minHeight: 150)
                        .font(themeStore.uiFont(.body))
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(tokens.primaryText)
                }
                if !attachments.isEmpty {
                    Section("附件") {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { index, item in
                            HStack(spacing: 10) {
                                Image(systemName: queuedAttachmentIcon(item))
                                    .foregroundStyle(tokens.accent)
                                Text(item.previewText)
                                    .lineLimit(1)
                                Spacer()
                                Button(role: .destructive) {
                                    attachments.remove(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("删除附件")
                            }
                        }
                    }
                }
                Section {
                    Text("编辑只影响本机待发送内容；保存后仍按原队列顺序发送。")
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                }
            }
            .navigationTitle("编辑待发送消息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(draft.payload(text: text, attachments: attachments))
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return draft.turn.intent.startsGoal ? hasText : (hasText || !attachments.isEmpty)
    }

    private func queuedAttachmentIcon(_ item: CodexAppServerUserInput) -> String {
        switch item {
        case .image, .localImage:
            return "photo"
        case .skill:
            return "wand.and.stars"
        case .mention:
            return "at"
        case .text:
            return "text.alignleft"
        }
    }
}

struct QueuedTurnManagerSheet: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let turns: [QueuedTurnEntry]
    let canGuideCurrentTurn: Bool
    let onUpdate: (QueuedTurnEntry, CodexAppServerTurnPayload) -> Void
    let onDelete: (QueuedTurnEntry) -> Void
    let onRetry: (QueuedTurnEntry) -> Void
    let onGuideNow: (QueuedTurnEntry) -> Void
    let onMove: (IndexSet, Int) -> Void
    @State private var editingTurn: QueuedTurnEditorDraft?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        NavigationStack {
            Group {
                if turns.isEmpty {
                    ContentUnavailableView("没有待发送消息", systemImage: "tray")
                } else {
                    List {
                        Section {
                            ForEach(turns) { turn in
                                HStack(spacing: 10) {
                                    Image(systemName: turn.displayIcon)
                                        .foregroundStyle(turn.displayTint(tokens: tokens))
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(turn.previewText.isEmpty ? "（仅附件）" : turn.previewText)
                                            .lineLimit(2)
                                            .font(themeStore.uiFont(.body, weight: .medium))
                                        Text(turn.displayStatusText)
                                            .font(themeStore.uiFont(.caption))
                                            .foregroundStyle(turn.displayTint(tokens: tokens))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Menu {
                                        Button("编辑", systemImage: "pencil") {
                                            editingTurn = QueuedTurnEditorDraft(turn: turn)
                                        }
                                        .disabled(turn.dispatchState == .dispatching)
                                        if turn.intent.canGuideCurrentTurn {
                                            Button("立即引导当前回复", systemImage: "text.bubble") {
                                                onGuideNow(turn)
                                            }
                                            .disabled(!canGuideCurrentTurn || turn.dispatchState != .waiting)
                                        }
                                        if turn.dispatchState == .needsConfirmation {
                                            Button("确认并重试", systemImage: "arrow.clockwise") {
                                                onRetry(turn)
                                            }
                                        }
                                        Divider()
                                        Button("删除", systemImage: "trash", role: .destructive) {
                                            onDelete(turn)
                                        }
                                        .disabled(turn.dispatchState == .dispatching)
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                    }
                                }
                            }
                            .onMove(perform: onMove)
                        } footer: {
                            Text("按住右侧拖动可调整下一轮发送顺序。队列保存在此设备，App 重新打开后会继续。")
                        }
                    }
                }
            }
            .navigationTitle("待发送队列")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                if turns.count > 1 {
                    ToolbarItem(placement: .primaryAction) {
                        EditButton()
                    }
                }
            }
            .sheet(item: $editingTurn) { draft in
                QueuedTurnEditorSheet(draft: draft) { payload in
                    onUpdate(draft.turn, payload)
                }
                .environmentObject(themeStore)
            }
        }
    }

}

// 待发送条目的图标、色彩和状态文案由 Composer 预览行和管理面板共用，
// 集中在一处避免两侧文案漂移。
extension QueuedTurnEntry {
    var displayIcon: String {
        switch dispatchState {
        case .waiting:
            return intent.startsGoal ? "target" : "clock"
        case .dispatching:
            return "paperplane"
        case .needsConfirmation:
            return "exclamationmark.triangle"
        }
    }

    func displayTint(tokens: ThemeTokens) -> Color {
        switch dispatchState {
        case .waiting:
            return tokens.secondaryText
        case .dispatching:
            return tokens.accent
        case .needsConfirmation:
            return tokens.warning
        }
    }

    var displayStatusText: String {
        switch dispatchState {
        case .waiting:
            if waitsForAcceptedTurnStart == true {
                return "正在确认上一轮状态 · \(intent.title)"
            }
            return expectedTurnID == nil ? "等待连接后发送 · \(intent.title)" : "当前回复完成后发送 · \(intent.title)"
        case .dispatching:
            return "正在发送 · \(intent.title)"
        case .needsConfirmation:
            return lastError ?? "发送结果需要确认"
        }
    }
}

struct ComposerStatusTray: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let sessionControlNotice: String?
    let quotaNotice: CodexQuotaNotice?
    let usage: CodexUsageDisplaySummary?
    let goal: ThreadGoal?
    let isGoalExpanded: Bool
    let isGoalUpdating: Bool
    let goalErrorMessage: String?
    let isRefreshDisabled: Bool
    let onTakeOver: () -> Void
    let onRefreshUsage: () -> Void
    let onEditGoal: () -> Void
    let onTogglePauseGoal: () -> Void
    let onCompleteGoal: () -> Void
    let onClearGoal: () -> Void
    let onToggleGoalExpanded: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let tint = trayTint(tokens: tokens)

        VStack(alignment: .leading, spacing: isGoalExpanded ? 8 : 0) {
            // 展开态把状态内容和收起按钮放到同一行，避免先出现一整行空白按钮区。
            if isGoalExpanded {
                expandedTrayContent(tokens: tokens)
            } else {
                collapsedHeader(tokens: tokens)
            }

            if let trimmedGoalError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(trimmedGoalError)
                        .lineLimit(2)
                }
                .font(themeStore.uiFont(.caption2, weight: .medium))
                .foregroundStyle(tokens.warning)
            }
        }
        .padding(isGoalExpanded ? 10 : 8)
        .frame(maxWidth: isGoalExpanded ? 680 : .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.28))
        }
        .accessibilityElement(children: .contain)
    }

    private func collapsedHeader(tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if sessionControlNotice != nil {
                        collapsedChip(title: "观察", systemImage: "eye", tint: tokens.secondaryText, tokens: tokens)
                    }
                    if quotaNotice != nil {
                        collapsedChip(title: "额度", systemImage: "speedometer", tint: tokens.warning, tokens: tokens)
                    } else if usage != nil {
                        collapsedChip(title: "额度", systemImage: "speedometer", tint: tokens.warning, tokens: tokens)
                    }
                    if let goal {
                        collapsedChip(title: collapsedGoalChipTitle(for: goal.status), systemImage: "target", tint: goalStatusTint(goal, tokens: tokens), tokens: tokens)
                    }
                }
                .padding(.vertical, 1)
            }
            .layoutPriority(1)

            iconButton(
                title: isGoalExpanded ? "收起状态" : "展开状态",
                systemImage: isGoalExpanded ? "chevron.up" : "chevron.down",
                tint: tokens.secondaryText,
                isDisabled: false,
                action: onToggleGoalExpanded
            )
        }
    }

    @ViewBuilder
    private func expandedTrayContent(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            expandedHeaderRow(tokens: tokens)
            if let goal {
                expandedGoalDetails(goal, tokens: tokens)
            }
        }
    }

    private func expandedHeaderRow(tokens: ThemeTokens) -> some View {
        HStack(alignment: .top, spacing: 8) {
            expandedHeaderSummary(tokens: tokens)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            iconButton(
                title: "收起状态",
                systemImage: "chevron.up",
                tint: tokens.secondaryText,
                isDisabled: false,
                action: onToggleGoalExpanded
            )
        }
    }

    @ViewBuilder
    private func expandedHeaderSummary(tokens: ThemeTokens) -> some View {
        if hasStatusModules {
            adaptiveStatusModules(tokens: tokens)
        } else if let goal {
            collapsedChip(
                title: collapsedGoalChipTitle(for: goal.status),
                systemImage: "target",
                tint: goalStatusTint(goal, tokens: tokens),
                tokens: tokens
            )
        }
    }

    private var hasStatusModules: Bool {
        sessionControlNotice != nil || quotaNotice != nil || usage != nil
    }

    private func collapsedChip(title: String, systemImage: String, tint: Color, tokens: ThemeTokens) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(tokens.surface.opacity(0.74), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(tint.opacity(0.18))
        }
        .accessibilityElement(children: .combine)
    }

    private func adaptiveStatusModules(tokens: ThemeTokens) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                statusModuleContent(tokens: tokens)
            }
            VStack(alignment: .leading, spacing: 6) {
                statusModuleContent(tokens: tokens)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statusModuleContent(tokens: ThemeTokens) -> some View {
        if let sessionControlNotice {
            observingSegment(sessionControlNotice, tokens: tokens)
        }
        if let quotaNotice {
            quotaSegment(quotaNotice, tokens: tokens)
        } else if let usage {
            usageSegment(usage, tokens: tokens)
        }
    }

    private func observingSegment(_ notice: String, tokens: ThemeTokens) -> some View {
        traySegment(tokens: tokens, tint: tokens.secondaryText, minWidth: 132) {
            HStack(spacing: 7) {
                segmentIcon("eye", tint: tokens.secondaryText)
                Text("仅观察")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                Button(action: onTakeOver) {
                    Text("接管")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.accent)
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(notice)
        }
    }

    private func quotaSegment(_ notice: CodexQuotaNotice, tokens: ThemeTokens) -> some View {
        traySegment(tokens: tokens, tint: tokens.warning, minWidth: 230, layoutPriority: 1) {
            HStack(spacing: 8) {
                segmentIcon("speedometer", tint: tokens.warning)
                Text(notice.blocksSending ? "额度已用尽" : notice.title)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.warning)
                    .lineLimit(1)
                Text(notice.message)
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                    .layoutPriority(1)
                refreshButton(tint: tokens.warning)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func usageSegment(_ usage: CodexUsageDisplaySummary, tokens: ThemeTokens) -> some View {
        traySegment(tokens: tokens, tint: tokens.warning, minWidth: 250, layoutPriority: 1) {
            HStack(spacing: 8) {
                segmentIcon("speedometer", tint: tokens.warning)
                Text("额度 \(usage.primaryText)")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.warning)
                    .lineLimit(1)
                Text(usage.secondaryText)
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                    .layoutPriority(1)
                refreshButton(tint: tokens.warning)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func expandedGoalDetails(_ goal: ThreadGoal, tokens: ThemeTokens) -> some View {
        let tint = goalStatusTint(goal, tokens: tokens)
        return VStack(alignment: .leading, spacing: 8) {
            Text(goal.objective)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(3)

            if let progress = goal.budgetProgressFraction {
                ProgressView(value: progress)
                    .tint(tint)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("目标 token 预算进度")
                    .accessibilityValue(goal.budgetPercentText ?? goal.progressText)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    goalMetrics(goal, tokens: tokens)
                    Spacer(minLength: 8)
                    goalActionRow(goal, tint: tint, tokens: tokens)
                }
                VStack(alignment: .leading, spacing: 8) {
                    goalMetrics(goal, tokens: tokens)
                    goalActionRow(goal, tint: tint, tokens: tokens)
                }
            }
        }
    }

    private func goalMetrics(_ goal: ThreadGoal, tokens: ThemeTokens) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                goalDetailText("状态 \(goal.status.displayText)", symbol: "circle.dashed", tokens: tokens)
                goalDetailText("进度 \(goal.progressText)", symbol: "gauge.with.dots.needle.33percent", tokens: tokens)
                if let percent = goal.budgetPercentText {
                    goalDetailText("预算 \(percent)", symbol: "percent", tokens: tokens)
                }
                goalDetailText("用时 \(goal.elapsedText)", symbol: "timer", tokens: tokens)
            }
            VStack(alignment: .leading, spacing: 4) {
                goalDetailText("状态 \(goal.status.displayText)", symbol: "circle.dashed", tokens: tokens)
                goalDetailText("进度 \(goal.progressText)", symbol: "gauge.with.dots.needle.33percent", tokens: tokens)
                if let percent = goal.budgetPercentText {
                    goalDetailText("预算 \(percent)", symbol: "percent", tokens: tokens)
                }
                goalDetailText("用时 \(goal.elapsedText)", symbol: "timer", tokens: tokens)
            }
        }
    }

    private func goalActionRow(_ goal: ThreadGoal, tint: Color, tokens: ThemeTokens) -> some View {
        HStack(spacing: 6) {
            iconButton(title: "编辑目标", systemImage: "pencil", tint: tokens.secondaryText, isDisabled: isGoalUpdating, action: onEditGoal)
            iconButton(title: primaryGoalActionTitle(for: goal.status), systemImage: primaryGoalActionSymbol(for: goal.status), tint: tint, isDisabled: isGoalUpdating, action: onTogglePauseGoal)
            iconButton(title: "标记完成", systemImage: "checkmark.circle", tint: tokens.success, isDisabled: isGoalUpdating || goal.status == .complete, action: onCompleteGoal)
            iconButton(title: "清除目标", systemImage: "trash", tint: .red, isDisabled: isGoalUpdating, action: onClearGoal)
        }
    }

    private func traySegment<Content: View>(
        tokens: ThemeTokens,
        tint: Color,
        minWidth: CGFloat? = nil,
        layoutPriority: Double = 0,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minWidth: minWidth, minHeight: 38)
            .background(tokens.surface.opacity(0.74), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tint.opacity(0.18))
            }
            .layoutPriority(layoutPriority)
    }

    private func segmentIcon(_ systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(themeStore.uiFont(.caption, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
            .background(tint.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }

    private func refreshButton(tint: Color) -> some View {
        Button(action: onRefreshUsage) {
            Image(systemName: "arrow.clockwise")
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isRefreshDisabled ? themeStore.tokens(for: colorScheme).tertiaryText : tint)
        .disabled(isRefreshDisabled)
        .help("刷新 Codex 使用量")
        .accessibilityLabel("刷新 Codex 使用量")
    }

    private func iconButton(
        title: String,
        systemImage: String,
        tint: Color,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(isDisabled ? themeStore.tokens(for: colorScheme).tertiaryText : tint)
                .frame(width: 30, height: 30)
                .background(themeStore.tokens(for: colorScheme).elevatedSurface.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(themeStore.tokens(for: colorScheme).border.opacity(0.72))
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(title)
        .accessibilityLabel(title)
    }

    private func goalDetailText(_ text: String, symbol: String, tokens: ThemeTokens) -> some View {
        Label(text, systemImage: symbol)
            .font(themeStore.uiFont(.caption2, weight: .medium))
            .foregroundStyle(tokens.secondaryText)
            .lineLimit(1)
    }

    private var trimmedGoalError: String? {
        let trimmed = goalErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func trayTint(tokens: ThemeTokens) -> Color {
        if quotaNotice != nil || usage != nil {
            return tokens.warning
        }
        if let goal {
            return goalStatusTint(goal, tokens: tokens)
        }
        return tokens.secondaryText
    }

    private func goalStatusTint(_ goal: ThreadGoal, tokens: ThemeTokens) -> Color {
        switch goal.status {
        case .active:
            return tokens.goalActive
        case .paused:
            return .secondary
        case .blocked, .usageLimited, .budgetLimited:
            return tokens.warning
        case .complete:
            return tokens.accent
        }
    }

    private func primaryGoalActionTitle(for status: ThreadGoalStatus) -> String {
        status == .active ? "暂停目标" : "继续目标"
    }

    private func primaryGoalActionSymbol(for status: ThreadGoalStatus) -> String {
        status == .active ? "pause.circle" : "play.circle"
    }

    private func collapsedGoalChipTitle(for status: ThreadGoalStatus) -> String {
        switch status {
        case .active:
            return "目标"
        case .paused:
            return "暂停"
        case .blocked:
            return "受阻"
        case .usageLimited:
            return "额度"
        case .budgetLimited:
            return "预算"
        case .complete:
            return "完成"
        }
    }
}
