import SwiftUI

struct PendingApprovalActionCard: View {
    let approval: ApprovalSummary
    let isSendingDecision: Bool
    let onDecision: (String) -> Void

    @State private var persistentGrant: PersistentPermissionGrant?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent(L10n.text("ui.type"), value: approval.kind)
                LabeledContent(L10n.text("ui.request"), value: approval.title)
                if let risk = approval.risk {
                    LabeledContent(L10n.text("ui.risk"), value: risk)
                }
                if let count = approval.count {
                    LabeledContent(L10n.text("ui.impact_items"), value: L10n.plural("ui.items_count", count: count))
                }
                DisclosureGroup(L10n.text("ui.approval_details")) {
                    if let body = approval.body {
                        Text(body)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(L10n.text("ui.approval_details_not_available"))
                            .foregroundStyle(.secondary)
                    }
                }

                if isSendingDecision {
                    Label(L10n.text("ui.decision_sent"), systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !approval.hasDecisionContext {
                    Label(L10n.text("ui.claude_bridge_provides_no_verifiable_command_path_or"), systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                approvalButtons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(L10n.text("ui.waiting_for_approval"), systemImage: "exclamationmark.shield")
                .foregroundStyle(.orange)
        }
        // 审批卡位于输入框上方，用户无需跳转到 Inspector 才能作出决定。
        .accessibilityElement(children: .contain)
        .sheet(item: $persistentGrant) { grant in
            PersistentPermissionConfirmationSheet(grant: grant) {
                onDecision("acceptWithPermissionUpdate")
            }
        }
    }

    private var approvalButtons: some View {
        ControlGroup {
            Button(role: .destructive) {
                onDecision("decline")
            } label: {
                Label(L10n.text("ui.reject"), systemImage: "xmark.circle")
            }
            .disabled(isSendingDecision)
            .accessibilityLabel(L10n.text("ui.deny_approval"))
            .accessibilityHint(L10n.text("ui.deny_is_always_available"))

            Button {
                onDecision("accept")
            } label: {
                Label(L10n.text("ui.approve_once"), systemImage: "checkmark.circle.fill")
            }
            .disabled(isSendingDecision || !approval.hasDecisionContext)
            .accessibilityLabel(L10n.text("ui.approval_36f0d72e"))
            .accessibilityValue(approval.hasDecisionContext ? L10n.text("ui.available") : L10n.text("ui.approval_details_not_available"))
            .accessibilityHint(approval.hasDecisionContext ? L10n.text("ui.approve_this_request") : L10n.text("ui.approval_details_are_missing_and_cannot_be_approved"))

            if approval.canPersistPermission, let rules = approval.persistentPermissionRules {
                Button {
                    persistentGrant = PersistentPermissionGrant(
                        id: approval.id,
                        approvalTitle: approval.title,
                        rules: rules
                    )
                } label: {
                    Label(L10n.text("ui.always_allowed"), systemImage: "checkmark.shield")
                }
                .disabled(isSendingDecision || !approval.hasDecisionContext)
                .accessibilityHint(L10n.text("ui.after_confirmation_write_the_precise_rules_suggested_by"))
            }
        }
        .controlGroupStyle(.navigation)
        .controlSize(.large)
    }
}

struct PersistentPermissionGrant: Identifiable {
    let id: String
    let approvalTitle: String
    let rules: [String]
}

struct PersistentPermissionConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let grant: PersistentPermissionGrant
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("ui.current_request")) {
                    Text(grant.approvalTitle)
                }
                Section(L10n.text("ui.will_always_be_allowed")) {
                    ForEach(grant.rules, id: \.self) { rule in
                        Text(rule)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Section {
                    Text(L10n.text("ui.claude_will_append_the_above_precise_rules_to"))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.text("ui.confirm_always_allow"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.confirm_permission")) {
                        onConfirm()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct PendingUserInputDraft: Equatable {
    private(set) var selectedAnswers: [String: Set<String>] = [:]
    private(set) var freeformAnswers: [String: String] = [:]

    mutating func toggleOption(_ label: String, for question: AgentUserInputQuestion) {
        if question.allowsMultipleSelection {
            if selectedAnswers[question.id, default: []].contains(label) {
                selectedAnswers[question.id, default: []].remove(label)
            } else {
                selectedAnswers[question.id, default: []].insert(label)
            }
        } else {
            selectedAnswers[question.id] = [label]
        }
    }

    mutating func setFreeformAnswer(_ answer: String, for questionID: String) {
        freeformAnswers[questionID] = answer
    }

    func isSelected(_ label: String, for questionID: String) -> Bool {
        selectedAnswers[questionID, default: []].contains(label)
    }

    func freeformAnswer(for questionID: String) -> String {
        freeformAnswers[questionID] ?? ""
    }

    func answerPayload(for request: AgentUserInputRequest) -> [String: [String]] {
        var payload: [String: [String]] = [:]
        for question in request.questions {
            let values = answers(for: question)
            if !values.isEmpty {
                payload[question.id] = values
            }
        }
        return payload
    }

    func canSubmit(_ request: AgentUserInputRequest) -> Bool {
        request.questions.isEmpty || request.questions.allSatisfy { !answers(for: $0).isEmpty }
    }

    private func answers(for question: AgentUserInputQuestion) -> [String] {
        let selected = selectedAnswers[question.id] ?? []
        // 选项按服务端给出的顺序生成 payload；Set 只用于去重和快速切换，不能决定传输顺序。
        var values = question.options.map(\.label).filter { selected.contains($0) }
        let freeform = freeformAnswer(for: question.id).trimmingCharacters(in: .whitespacesAndNewlines)
        if !freeform.isEmpty {
            values.append(freeform)
        }
        return values
    }
}

struct PendingUserInputPresentation: Identifiable, Equatable {
    let request: AgentUserInputRequest

    var id: String {
        "\(request.threadID):\(request.id)"
    }
}

struct PendingUserInputFormState: Equatable {
    private(set) var activePresentationID: String?
    var draft = PendingUserInputDraft()

    mutating func activate(_ presentationID: String) {
        guard activePresentationID != presentationID else {
            return
        }
        // 同一请求关闭再打开要保留答案；只有 thread/request 真正变化时才清空。
        activePresentationID = presentationID
        draft = PendingUserInputDraft()
    }

    mutating func resetForSessionChange() {
        activePresentationID = nil
        draft = PendingUserInputDraft()
    }
}

struct PendingUserInputSelectionIdentity: Equatable {
    let sessionID: SessionID?
    let requestPresentationID: String?
}

struct PendingUserInputActionCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let request: AgentUserInputRequest
    let isSubmitting: Bool
    @Binding var draft: PendingUserInputDraft
    let onSubmit: ([String: [String]]) -> Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            PendingUserInputHeader(request: request, isSubmitting: isSubmitting, showsSectionLabel: true)
            PendingUserInputQuestions(
                request: request,
                isSubmitting: isSubmitting,
                usesFullWidthOptions: false,
                draft: $draft
            )
            PendingUserInputActionBar(
                request: request,
                isSubmitting: isSubmitting,
                draft: $draft,
                onSubmit: onSubmit
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.accent.opacity(0.28), lineWidth: 1)
        }
    }
}

struct PendingUserInputResumeButton: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let request: AgentUserInputRequest
    let isSubmitting: Bool
    let action: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(tokens.accent)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("ui.continue_filling_supplementary_information"))
                        .font(themeStore.uiFont(.subheadline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(request.title)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.up")
                        .font(themeStore.uiFont(.caption2, weight: .bold))
                        .foregroundStyle(tokens.tertiaryText)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tokens.accent.opacity(0.28), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
        .accessibilityLabel(L10n.text("ui.continue_filling_supplementary_information"))
        .accessibilityValue(request.title)
    }
}

struct PendingUserInputSheet: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dismiss) private var dismiss
    let presentation: PendingUserInputPresentation
    let isSubmitting: Bool
    @Binding var draft: PendingUserInputDraft
    let onSubmit: ([String: [String]]) -> Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PendingUserInputHeader(
                        request: presentation.request,
                        isSubmitting: isSubmitting,
                        showsSectionLabel: false
                    )
                    PendingUserInputQuestions(
                        request: presentation.request,
                        isSubmitting: isSubmitting,
                        usesFullWidthOptions: true,
                        draft: $draft
                    )
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PendingUserInputActionBar(
                    request: presentation.request,
                    isSubmitting: isSubmitting,
                    draft: $draft,
                    onSubmit: { answers in
                        let accepted = onSubmit(answers)
                        if accepted {
                            dismiss()
                        }
                        return accepted
                    }
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background {
                    if reduceTransparency {
                        tokens.background
                    } else {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .overlay(tokens.background.opacity(colorScheme == .light ? 0.76 : 0.62))
                    }
                }
                .shadow(color: .black.opacity(tokens.resolvedScheme == .light ? 0.08 : 0.24), radius: 12, y: -3)
            }
            .background(tokens.background)
            .navigationTitle(L10n.text("ui.supplementary_information"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.close")) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct PendingUserInputHeader: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let request: AgentUserInputRequest
    let isSubmitting: Bool
    let showsSectionLabel: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.bubble")
                .font(themeStore.uiFont(.callout, weight: .semibold))
                .foregroundStyle(tokens.accent)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                if showsSectionLabel {
                    Text(L10n.text("ui.supplementary_information"))
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.accent)
                }
                Text(request.title)
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if isSubmitting {
                    Label(L10n.text("ui.answer_sent"), systemImage: "hourglass")
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PendingUserInputQuestions: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let request: AgentUserInputRequest
    let isSubmitting: Bool
    let usesFullWidthOptions: Bool
    @Binding var draft: PendingUserInputDraft

    var body: some View {
        VStack(alignment: .leading, spacing: usesFullWidthOptions ? 14 : 12) {
            ForEach(request.questions) { question in
                questionBlock(question)
                    .padding(usesFullWidthOptions ? 14 : 0)
                    .background {
                        if usesFullWidthOptions {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(themeStore.tokens(for: colorScheme).elevatedSurface)
                        }
                    }
            }
        }
    }

    private func questionBlock(_ question: AgentUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if !question.header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(question.header)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
            }
            if !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(question.question)
                    .font(themeStore.uiFont(.subheadline))
                    .foregroundStyle(themeStore.tokens(for: colorScheme).primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !question.options.isEmpty {
                if question.allowsMultipleSelection {
                    Text(L10n.text("ui.multiple_selections_possible"))
                        .font(themeStore.uiFont(.caption2))
                        .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
                }
                optionButtons(for: question)
            }
            if question.isOther || question.options.isEmpty {
                answerField(for: question)
            }
        }
    }

    private func optionButtons(for question: AgentUserInputQuestion) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let columns = usesFullWidthOptions
            ? [GridItem(.flexible(), spacing: 8, alignment: .leading)]
            : [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)]

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(question.options) { option in
                let isSelected = draft.isSelected(option.label, for: question.id)
                Button {
                    draft.toggleOption(option.label, for: question)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(themeStore.uiFont(.callout, weight: .semibold))
                            .foregroundStyle(isSelected ? tokens.accent : tokens.tertiaryText)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.label)
                                .font(themeStore.uiFont(.subheadline, weight: .semibold))
                                .foregroundStyle(tokens.primaryText)
                            if let description = option.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                                Text(description)
                                    .font(themeStore.uiFont(.caption))
                                    .foregroundStyle(tokens.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: usesFullWidthOptions ? .infinity : 220, minHeight: 44, alignment: .leading)
                    .background(
                        isSelected ? tokens.selectionFill : tokens.inputBackground,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isSelected ? tokens.accent.opacity(0.5) : tokens.border, lineWidth: 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
            }
        }
    }

    @ViewBuilder
    private func answerField(for question: AgentUserInputQuestion) -> some View {
        if question.isSecret {
            SecureField(L10n.text("ui.other"), text: binding(for: question.id))
                .textFieldStyle(.roundedBorder)
                .disabled(isSubmitting)
        } else {
            TextField(L10n.text("ui.other"), text: binding(for: question.id), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(isSubmitting)
        }
    }

    private func binding(for questionID: String) -> Binding<String> {
        Binding(
            get: { draft.freeformAnswer(for: questionID) },
            set: { draft.setFreeformAnswer($0, for: questionID) }
        )
    }
}

private struct PendingUserInputActionBar: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let request: AgentUserInputRequest
    let isSubmitting: Bool
    @Binding var draft: PendingUserInputDraft
    let onSubmit: ([String: [String]]) -> Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        HStack(spacing: 10) {
            Button(L10n.text("ui.skip")) {
                _ = onSubmit([:])
            }
            .buttonStyle(.bordered)
            .tint(tokens.accent)
            .controlSize(.large)
            .frame(minHeight: 44)
            .disabled(isSubmitting)

            Button {
                _ = onSubmit(draft.answerPayload(for: request))
            } label: {
                if isSubmitting {
                    Label(L10n.text("ui.submitting"), systemImage: "hourglass")
                        .font(themeStore.uiFont(.body, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                } else {
                    Label(L10n.text("ui.submit_additional_information"), systemImage: "arrow.up.circle.fill")
                        .font(themeStore.uiFont(.body, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(tokens.accent)
            .controlSize(.large)
            .frame(minHeight: 44)
            .disabled(isSubmitting || !draft.canSubmit(request))
        }
    }
}
