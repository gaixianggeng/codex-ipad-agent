import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 8) {
            if let activity = sessionStore.selectedForegroundActivity {
                composerActivity(activity)
            }
            TextEditor(text: $draft)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(minHeight: 72, maxHeight: 130)
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
                    if draft.isEmpty {
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
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !sessionStore.isLoading else {
            return false
        }
        draft = ""
        Task {
            let accepted = await sessionStore.sendPrompt(text)
            if !accepted {
                await MainActor.run {
                    draft = text
                }
            }
        }
        return true
    }

    private var canSubmitDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sessionStore.isLoading
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
