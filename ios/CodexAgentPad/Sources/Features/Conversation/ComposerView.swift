import SwiftUI
import UIKit

private let composerTextContentInset: CGFloat = 10

struct ComposerView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var composerState = ComposerState()

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(spacing: 8) {
            if let activity = sessionStore.selectedForegroundActivity {
                composerActivity(activity)
            }
            runtimeChips
            pendingApprovalAction
            ComposerTextView(
                text: $composerState.draft,
                font: composerUIFont,
                textColor: UIColor(tokens.primaryText),
                tintColor: UIColor(tokens.accent),
                onSubmit: { submitDraft() }
            )
                .frame(minHeight: composerMinHeight, maxHeight: composerMaxHeight)
                .padding(composerTextContentInset)
                .background(tokens.elevatedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tokens.border)
                )
                .overlay(alignment: .topLeading) {
                    if composerState.isEmpty {
                        Text("输入任务或后续指令")
                            .font(themeStore.uiFont(.body))
                            .foregroundStyle(tokens.tertiaryText)
                            // 和 UITextView 外层 padding 保持同一个起点，避免占位文案与真实光标错位。
                            .padding(composerTextContentInset)
                            .allowsHitTesting(false)
                    }
                }

            ViewThatFits(in: .horizontal) {
                horizontalActions(showLabels: true)
                horizontalActions(showLabels: false)
                compactActions
            }
            .font(themeStore.uiFont(.callout))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(isCompactComposer ? 10 : 12)
        .background(tokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.border)
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

    private var isCompactComposer: Bool {
        horizontalSizeClass == .compact
    }

    private func horizontalActions(showLabels: Bool) -> some View {
        HStack(spacing: 10) {
            terminalControls(showLabels: showLabels)
            Spacer(minLength: 12)
            sendButton(showLabels: showLabels)
        }
    }

    private var compactActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            terminalControls(showLabels: false)
            HStack {
                Spacer()
                sendButton(showLabels: !isCompactComposer)
            }
        }
    }

    private func terminalControls(showLabels: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                composerState.toggleExpanded()
            } label: {
                controlLabel(
                    composerState.isExpanded ? "收起" : "展开",
                    systemImage: composerState.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    showLabels: showLabels
                )
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(composerState.isExpanded ? "收起输入框" : "展开输入框")

            Button {
                sessionStore.sendCtrlC()
            } label: {
                controlLabel("Ctrl-C", systemImage: "stop.circle", showLabels: showLabels)
            }
            .buttonStyle(.bordered)
            .disabled(sessionStore.selectedSession?.isRunning != true)
            .accessibilityLabel("发送 Ctrl-C")

            Button {
                submitDraft()
            } label: {
                controlLabel("Enter", systemImage: "return", showLabels: showLabels)
            }
            .buttonStyle(.bordered)
            .disabled(!canSubmitDraft)
            .accessibilityLabel("发送回车")

            Button(role: .destructive) {
                Task { await sessionStore.stopSelectedSession() }
            } label: {
                controlLabel("停止", systemImage: "xmark.circle", showLabels: showLabels)
            }
            .buttonStyle(.bordered)
            .disabled(sessionStore.selectedSession?.isRunning != true)
            .accessibilityLabel("停止当前会话")
        }
        .controlSize(isCompactComposer || !showLabels ? .small : .regular)
    }

    @ViewBuilder
    private var runtimeChips: some View {
        if !runtimeChipItems.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(runtimeChipItems, id: \.text) { item in
                        Label(item.text, systemImage: item.symbol)
                            .font(themeStore.uiFont(.caption, weight: .medium))
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

    private func sendButton(showLabels: Bool) -> some View {
        Button {
            submitDraft()
        } label: {
            controlLabel("发送", systemImage: "paperplane.fill", showLabels: showLabels)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(isCompactComposer || !showLabels ? .small : .regular)
        .help("发送")
        .disabled(!canSubmitDraft)
        .accessibilityLabel("发送")
    }

    @ViewBuilder
    private func controlLabel(_ title: String, systemImage: String, showLabels: Bool) -> some View {
        if showLabels {
            Label(title, systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
        }
    }

    private var composerMinHeight: CGFloat {
        if isCompactComposer {
            return composerState.isExpanded ? 118 : 60
        }
        return composerState.isExpanded ? 150 : 72
    }

    private var composerMaxHeight: CGFloat {
        if isCompactComposer {
            return composerState.isExpanded ? 190 : 108
        }
        return composerState.isExpanded ? 260 : 130
    }

    private var composerUIFont: UIFont {
        let size = themeStore.scaledFontSize(17)
        let base = UIFont.systemFont(ofSize: size)
        let design: UIFontDescriptor.SystemDesign
        switch themeStore.uiFontPreset {
        case .system:
            design = .default
        case .rounded:
            design = .rounded
        case .serif:
            design = .serif
        }
        guard let descriptor = base.fontDescriptor.withDesign(design) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: size)
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
        .font(themeStore.uiFont(.caption, weight: .medium))
        .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
    }
}

private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let font: UIFont
    let textColor: UIColor
    let tintColor: UIColor
    let onSubmit: () -> Bool

    func makeUIView(context: Context) -> CommandSubmitTextView {
        let textView = CommandSubmitTextView()
        textView.delegate = context.coordinator
        textView.onCommandSubmit = onSubmit
        textView.backgroundColor = .clear
        textView.font = font
        textView.textColor = textColor
        textView.tintColor = tintColor
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = false
        textView.showsVerticalScrollIndicator = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.accessibilityLabel = "输入任务或后续指令"
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: CommandSubmitTextView, context: Context) {
        context.coordinator.parent = self
        uiView.onCommandSubmit = onSubmit

        // 字体/颜色只在真正变化时赋值：UITextView 的 font setter 会让 TextKit 对整段文本重新排版，
        // 打字时（尤其是中文 marked text 合成期间）每次按键都重设会打断输入法合成并造成可感知卡顿。
        if uiView.font != font {
            uiView.font = font
        }
        if uiView.textColor != textColor {
            uiView.textColor = textColor
        }
        if uiView.tintColor != tintColor {
            uiView.tintColor = tintColor
        }

        guard uiView.text != text else {
            return
        }

        // 外部清空/恢复草稿时才同步 UIKit 文本；用户正常输入由 delegate 单向写回，
        // 避免中文 marked text 和光标位置在 SwiftUI 重算时被反复重置。
        let selectedRange = uiView.selectedRange
        uiView.text = text
        uiView.selectedRange = clampedRange(selectedRange, in: uiView.text)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func clampedRange(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(range.location, length)
        let remaining = max(0, length - location)
        return NSRange(location: location, length: min(range.length, remaining))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard parent.text != textView.text else {
                return
            }
            parent.text = textView.text
        }
    }
}

private final class CommandSubmitTextView: UITextView {
    var onCommandSubmit: (() -> Bool)?

    override var keyCommands: [UIKeyCommand]? {
        let submit = UIKeyCommand(
            title: "发送",
            image: nil,
            action: #selector(handleCommandReturn),
            input: "\r",
            modifierFlags: .command,
            propertyList: nil,
            alternates: [],
            discoverabilityTitle: "发送",
            attributes: [],
            state: .off
        )
        return (super.keyCommands ?? []) + [submit]
    }

    @objc private func handleCommandReturn() {
        // 普通回车仍由 UITextView 插入换行；只有 Command + Return 走发送。
        _ = onCommandSubmit?()
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
