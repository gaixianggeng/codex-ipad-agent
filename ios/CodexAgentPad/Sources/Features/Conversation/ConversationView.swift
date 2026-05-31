import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var conversationStore: ConversationStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            ComposerView()
        }
        .background(Color(.systemBackground))
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sessionStore.selectedSession?.title ?? "选择或新建会话")
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let message = sessionStore.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else if let message = sessionStore.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        if let session = sessionStore.selectedSession {
            return "\(session.project) · \(session.id)"
        }
        if let project = sessionStore.selectedProject {
            return project.path
        }
        return "请先配置 agentd 并选择项目"
    }

    private var messageList: some View {
        let messages = conversationStore.messages(for: sessionStore.selectedSessionID)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if messages.isEmpty {
                        ContentUnavailableView(
                            "还没有对话",
                            systemImage: "message",
                            description: Text("选择历史会话会加载 Codex 上下文；输入任务会启动或继续当前会话。")
                        )
                        .padding(.top, 80)
                    } else {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding(18)
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(messages: messages, proxy: proxy)
            }
            .onChange(of: messages.last?.content) { _, _ in
                scrollToBottom(messages: messages, proxy: proxy)
            }
        }
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

private struct MessageBubble: View {
    let message: ConversationMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 80)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(roleTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
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
            if message.role != .user {
                Spacer(minLength: 80)
            }
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
            return Color.primary
        case .assistant:
            return Color(.secondarySystemBackground)
        case .system:
            return Color.orange.opacity(0.12)
        }
    }

    private var foreground: Color {
        message.role == .user ? Color(.systemBackground) : Color.primary
    }

    private var border: Color {
        switch message.role {
        case .user:
            return Color.clear
        case .assistant:
            return Color.secondary.opacity(0.18)
        case .system:
            return Color.orange.opacity(0.25)
        }
    }
}
