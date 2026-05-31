import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 8) {
            Divider()
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 72, maxHeight: 130)
                .onKeyPress { keyPress in
                    guard keyPress.key == .return else {
                        return .ignored
                    }
                    if keyPress.modifiers.contains(.shift) {
                        return .ignored
                    }
                    submitDraft()
                    return .handled
                }
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.18))
                )
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("输入任务或后续指令")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 10) {
                Button {
                    sessionStore.sendCtrlC()
                } label: {
                    Label("Ctrl-C", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
                .disabled(sessionStore.selectedSession?.isRunning != true)

                Button {
                    sessionStore.sendEnter()
                } label: {
                    Label("Enter", systemImage: "return")
                }
                .buttonStyle(.bordered)
                .disabled(sessionStore.selectedSession?.isRunning != true)

                Button(role: .destructive) {
                    Task { await sessionStore.stopSelectedSession() }
                } label: {
                    Label("停止", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .disabled(sessionStore.selectedSession?.isRunning != true)

                Spacer()

                Button {
                    submitDraft()
                } label: {
                    Label("发送", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sessionStore.isLoading)
            }
            .font(.callout)
        }
        .padding(14)
        .background(Color(.systemBackground))
    }

    private func submitDraft() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !sessionStore.isLoading else {
            return
        }
        draft = ""
        Task { await sessionStore.sendPrompt(text) }
    }
}
