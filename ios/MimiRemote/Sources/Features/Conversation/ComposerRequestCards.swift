import SwiftUI

struct PendingApprovalActionCard: View {
    let approval: ApprovalSummary
    let isSendingDecision: Bool
    let onDecision: (String) -> Void

    @State private var persistentGrant: PersistentPermissionGrant?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("类型", value: approval.kind)
                LabeledContent("请求", value: approval.title)
                if let risk = approval.risk {
                    LabeledContent("风险", value: risk)
                }
                if let count = approval.count {
                    LabeledContent("影响项", value: "\(count) 项")
                }
                DisclosureGroup("审批详情") {
                    if let body = approval.body {
                        Text(body)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("审批详情不可用")
                            .foregroundStyle(.secondary)
                    }
                }

                if isSendingDecision {
                    Label("决定已发送", systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !approval.hasDecisionContext {
                    Label("Claude bridge 未提供可核对的命令、路径或工具输入；为避免误批准，只能拒绝。请升级 bridge 后重试。", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                approvalButtons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("等待审批", systemImage: "exclamationmark.shield")
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
                Label("拒绝", systemImage: "xmark.circle")
            }
            .disabled(isSendingDecision)
            .accessibilityLabel("拒绝审批")
            .accessibilityHint("拒绝始终可用")

            Button {
                onDecision("accept")
            } label: {
                Label("批准一次", systemImage: "checkmark.circle.fill")
            }
            .disabled(isSendingDecision || !approval.hasDecisionContext)
            .accessibilityLabel("批准审批")
            .accessibilityValue(approval.hasDecisionContext ? "可用" : "审批详情不可用")
            .accessibilityHint(approval.hasDecisionContext ? "批准这项请求" : "缺少审批详情，无法批准")

            if approval.canPersistPermission, let rules = approval.persistentPermissionRules {
                Button {
                    persistentGrant = PersistentPermissionGrant(
                        id: approval.id,
                        approvalTitle: approval.title,
                        rules: rules
                    )
                } label: {
                    Label("始终允许", systemImage: "checkmark.shield")
                }
                .disabled(isSendingDecision || !approval.hasDecisionContext)
                .accessibilityHint("确认后把 Claude 建议的精确规则写入当前项目本地设置")
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
                Section("当前请求") {
                    Text(grant.approvalTitle)
                }
                Section("将始终允许") {
                    ForEach(grant.rules, id: \.self) { rule in
                        Text(rule)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Section {
                    Text("Claude 会把以上精确规则追加到当前项目的 .claude/settings.local.json。不会授予全局权限，也不会扩大规则范围。")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("确认始终允许")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认允许") {
                        onConfirm()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct PendingUserInputActionCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let request: AgentUserInputRequest
    let isSubmitting: Bool
    let onSubmit: ([String: [String]]) -> Void

    @State private var selectedAnswers: [String: Set<String>] = [:]
    @State private var freeformAnswers: [String: String] = [:]

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            header

            ForEach(request.questions) { question in
                questionBlock(question)
            }

            HStack(spacing: 10) {
                Button("跳过") {
                    onSubmit([:])
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isSubmitting)

                Button {
                    onSubmit(answerPayload)
                } label: {
                    if isSubmitting {
                        Label("提交中", systemImage: "hourglass")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 30)
                    } else {
                        Label("提交补充信息", systemImage: "arrow.up.circle.fill")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(tokens.accent)
                .controlSize(.large)
                .disabled(isSubmitting || !canSubmit)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.accent.opacity(0.28), lineWidth: 1)
        }
    }

    private var header: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.bubble")
                .font(.callout.weight(.semibold))
                .foregroundStyle(tokens.accent)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text("补充信息")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tokens.accent)
                Text(request.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if isSubmitting {
                    Label("答案已发送", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func questionBlock(_ question: AgentUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(question.header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(question.question)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !question.options.isEmpty {
                if question.allowsMultipleSelection {
                    Text("可多选")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(question.options) { option in
                let isSelected = selectedAnswers[question.id, default: []].contains(option.label)
                Button {
                    if question.allowsMultipleSelection {
                        if isSelected {
                            selectedAnswers[question.id, default: []].remove(option.label)
                        } else {
                            selectedAnswers[question.id, default: []].insert(option.label)
                        }
                    } else {
                        selectedAnswers[question.id] = [option.label]
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(option.label, systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if let description = option.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                            Text(description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(isSelected ? tokens.accent : nil)
                .disabled(isSubmitting)
            }
        }
    }

    @ViewBuilder
    private func answerField(for question: AgentUserInputQuestion) -> some View {
        if question.isSecret {
            SecureField("Other", text: binding(for: question.id))
                .textFieldStyle(.roundedBorder)
                .disabled(isSubmitting)
        } else {
            TextField("Other", text: binding(for: question.id), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .disabled(isSubmitting)
        }
    }

    private func binding(for questionID: String) -> Binding<String> {
        Binding(
            get: { freeformAnswers[questionID] ?? "" },
            set: { freeformAnswers[questionID] = $0 }
        )
    }

    private var answerPayload: [String: [String]] {
        var payload: [String: [String]] = [:]
        for question in request.questions {
            let answers = answers(for: question)
            if !answers.isEmpty {
                payload[question.id] = answers
            }
        }
        return payload
    }

    private var canSubmit: Bool {
        if request.questions.isEmpty {
            return true
        }
        return request.questions.allSatisfy { !answers(for: $0).isEmpty }
    }

    private func answers(for question: AgentUserInputQuestion) -> [String] {
        let selected = selectedAnswers[question.id] ?? []
        var values = question.options.map(\.label).filter { selected.contains($0) }
        let freeform = (freeformAnswers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !freeform.isEmpty {
            values.append(freeform)
        }
        return values
    }
}
