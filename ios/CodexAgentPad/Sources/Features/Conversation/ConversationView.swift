import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var conversationStore: ConversationStore

    var body: some View {
        VStack(spacing: 0) {
            topStatusStrip
            messageList
            HStack {
                Spacer(minLength: 0)
                ComposerView()
                    .frame(maxWidth: 920)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
        }
        .background(workbenchBackground.ignoresSafeArea())
    }

    @ViewBuilder
    private var topStatusStrip: some View {
        if sessionStore.errorMessage != nil || sessionStore.selectedForegroundActivity != nil {
            HStack {
                Spacer(minLength: 0)
                foregroundStatus
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private var foregroundStatus: some View {
        if let message = sessionStore.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(statusChipBackground)
                .clipShape(Capsule())
        } else if let activity = sessionStore.selectedForegroundActivity {
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
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(workbenchSecondaryText)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(statusChipBackground)
            .clipShape(Capsule())
        }
    }

    private var messageList: some View {
        let messages = conversationStore.messages(for: sessionStore.selectedSessionID)
        return GeometryReader { geometry in
            let contentWidth = max(0, geometry.size.width - 48)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            emptyState
                            .padding(.top, 80)
                        } else {
                            ForEach(messages) { message in
                                MessageRow(message: message, rowWidth: contentWidth)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(width: geometry.size.width, alignment: .topLeading)
                }
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(messages: messages, proxy: proxy)
                }
                .onChange(of: messages.last?.content) { _, _ in
                    scrollToBottom(messages: messages, proxy: proxy)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "message")
                .font(.title2)
                .foregroundStyle(workbenchSecondaryText)
            Text("还没有对话")
                .font(.headline)
                .foregroundStyle(workbenchPrimaryText)
            Text("选择历史会话会加载 Codex 上下文；输入任务会启动或继续当前会话。")
                .font(.callout)
                .foregroundStyle(workbenchSecondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private var workbenchBackground: Color {
        Color(red: 0.10, green: 0.13, blue: 0.18)
    }

    private var statusChipBackground: Color {
        Color.white.opacity(0.07)
    }

    private var workbenchPrimaryText: Color {
        Color.white.opacity(0.90)
    }

    private var workbenchSecondaryText: Color {
        Color.white.opacity(0.62)
    }

    private func scrollToBottom(messages: [ConversationMessage], proxy: ScrollViewProxy) {
        guard let last = messages.last else {
            return
        }
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

private struct MessageRow: View {
    let message: ConversationMessage
    let rowWidth: CGFloat

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 24)
            }
            MessageBubble(message: message)
            if message.role != .user {
                Spacer(minLength: 24)
            }
        }
        .frame(width: rowWidth, alignment: rowAlignment)
    }

    private var rowAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }
}

private struct MessageBubble: View {
    let message: ConversationMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if message.role == .system {
                Text(roleTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.56))
            }
            Text(message.content)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(background)
        .foregroundStyle(foreground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
    }

    private var maxBubbleWidth: CGFloat {
        switch message.role {
        case .user:
            return 560
        case .assistant:
            return 720
        case .system:
            return 640
        }
    }

    private var roleTitle: String {
        switch message.role {
        case .user:
            return "你"
        case .assistant:
            return "Codex"
        case .system:
            return "系统"
        }
    }

    private var background: Color {
        switch message.role {
        case .user:
            return Color(red: 0.42, green: 0.28, blue: 0.08)
        case .assistant:
            return Color.clear
        case .system:
            return Color.orange.opacity(0.12)
        }
    }

    private var foreground: Color {
        switch message.role {
        case .user:
            return .white
        case .assistant:
            return Color.white.opacity(0.88)
        case .system:
            return Color.white.opacity(0.80)
        }
    }

    private var border: Color {
        switch message.role {
        case .user:
            return Color.orange.opacity(0.35)
        case .assistant:
            return Color.clear
        case .system:
            return Color.orange.opacity(0.25)
        }
    }
}
