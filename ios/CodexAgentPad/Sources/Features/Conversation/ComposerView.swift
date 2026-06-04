import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var composerState = ComposerState()

    var body: some View {
        VStack(spacing: 8) {
            if let activity = sessionStore.selectedForegroundActivity {
                composerActivity(activity)
            }
            runtimeChips
            pendingApprovalAction
            TextEditor(text: $composerState.draft)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(minHeight: composerMinHeight, maxHeight: composerMaxHeight)
                .onKeyPress { keyPress in
                    guard keyPress.key == .return else {
                        return .ignored
                    }
                    // 普通回车交给 TextEditor 换行；只有 Command + 回车才提交消息。
                    guard keyPress.modifiers.contains(.command) else {
                        return .ignored
                    }
                    return submitDraft() ? .handled : .ignored
                }
                .padding(10)
                .scrollContentBackground(.hidden)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(.separator))
                )
                .overlay(alignment: .topLeading) {
                    if composerState.isEmpty {
                        Text("输入任务或后续指令")
                            .foregroundStyle(Color(.placeholderText))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }

            ViewThatFits(in: .horizontal) {
                horizontalActions
                compactActions
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(.separator))
        )
    }

    @discardableResult
    private func submitDraft() -> Bool {
        guard let text = composerState.takeDraftForSubmit(isLoading: sessionStore.isLoading) else {
            return false
        }
        Task {
            let accepted = await sessionStore.sendPrompt(text)
            if !accepted {
                await MainActor.run {
                    composerState.restore(text)
                }
            }
        }
        return true
    }

    private var canSubmitDraft: Bool {
        composerState.canSubmit(isLoading: sessionStore.isLoading)
    }

    private var horizontalActions: some View {
        HStack(spacing: 10) {
            terminalControls
            Spacer(minLength: 12)
            sendButton
        }
    }

    private var compactActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            terminalControls
            HStack {
                Spacer()
                sendButton
            }
        }
    }

    private var terminalControls: some View {
        HStack(spacing: 8) {
            Button {
                composerState.toggleExpanded()
            } label: {
                Label(composerState.isExpanded ? "收起" : "展开", systemImage: composerState.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.bordered)

            Button {
                sessionStore.sendCtrlC()
            } label: {
                Label("Ctrl-C", systemImage: "stop.circle")
            }
            .buttonStyle(.bordered)
            .disabled(sessionStore.selectedSession?.isRunning != true)

            Button {
                submitDraft()
            } label: {
                Label("Enter", systemImage: "return")
            }
            .buttonStyle(.bordered)
            .disabled(!canSubmitDraft)

            Button(role: .destructive) {
                Task { await sessionStore.stopSelectedSession() }
            } label: {
                Label("停止", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .disabled(sessionStore.selectedSession?.isRunning != true)
        }
    }

    @ViewBuilder
    private var runtimeChips: some View {
        if !runtimeChipItems.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(runtimeChipItems, id: \.text) { item in
                        Label(item.text, systemImage: item.symbol)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(item.tint.opacity(0.12), in: Capsule())
                            .foregroundStyle(item.tint)
                    }
                }
            }
        }
    }

    private var runtimeChipItems: [(text: String, symbol: String, tint: Color)] {
        guard let session = sessionStore.selectedSession else {
            return []
        }
        var items: [(text: String, symbol: String, tint: Color)] = []
        if session.activeTurnID != nil {
            items.append(("active turn", "bolt.fill", .green))
        }
        if let lastSeq = session.lastSeq {
            items.append(("seq \(lastSeq)", "number", .secondary))
        }
        if let usage = session.usage?.compactText {
            items.append((usage, "gauge.with.dots.needle.33percent", .secondary))
        }
        if let rateLimit = session.rateLimit?.compactText {
            items.append((rateLimit, "speedometer", .secondary))
        }
        if session.source == "agentd" {
            items.append(("PTY fallback", "terminal", .secondary))
        }
        return items
    }

    @ViewBuilder
    private var pendingApprovalAction: some View {
        if let approval = sessionStore.selectedSession?.pendingApproval {
            PendingApprovalActionCard(
                approval: approval,
                onApprove: { sessionStore.decideApproval(approval, accept: true) },
                onDecline: { sessionStore.decideApproval(approval, accept: false) }
            )
        }
    }

    private var sendButton: some View {
        Button {
            submitDraft()
        } label: {
            Label("发送", systemImage: "paperplane.fill")
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canSubmitDraft)
    }

    private var composerMinHeight: CGFloat {
        composerState.isExpanded ? 150 : 72
    }

    private var composerMaxHeight: CGFloat {
        composerState.isExpanded ? 260 : 130
    }

    private func composerActivity(_ activity: SessionForegroundActivity) -> some View {
        HStack(spacing: 7) {
            if activity.showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(.green)
            } else {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
            }
            Text(activity.title)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

private struct PendingApprovalActionCard: View {
    let approval: ApprovalSummary
    let onApprove: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text("等待审批")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(approval.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    approvalMeta
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    approvalButtons
                }

                VStack(alignment: .leading, spacing: 8) {
                    approvalButtons
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 审批是当前 turn 的阻塞点，放在输入框上方比放在 Inspector 更接近用户决策动作。
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.30), lineWidth: 1)
        }
    }

    private var approvalMeta: some View {
        HStack(spacing: 8) {
            Label(approval.kind, systemImage: "tag")
            if let count = approval.count {
                Label("\(count) 项", systemImage: "number")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var approvalButtons: some View {
        Group {
            Button(role: .destructive, action: onDecline) {
                Label("拒绝", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)

            Button(action: onApprove) {
                Label("批准", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .controlSize(.small)
        .font(.caption.weight(.semibold))
    }
}
