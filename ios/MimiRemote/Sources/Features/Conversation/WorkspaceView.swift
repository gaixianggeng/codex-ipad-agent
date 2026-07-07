import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    var onOpenWorkspaces: (() -> Void)? = nil

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if sessionStore.selectedProjectID == nil && sessionStore.selectedSessionID == nil {
                emptyState(tokens: tokens)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ConversationView()
            }
        }
        .background(tokens.background)
    }

    private func emptyState(tokens: ThemeTokens) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 7) {
                Text("选择会话")
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text("从左侧选择历史会话继续上下文；需要打开目录时，可以先到工作区添加常用项目。")
                    .font(themeStore.uiFont(.callout))
                    .foregroundStyle(tokens.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let onOpenWorkspaces {
                Button(action: onOpenWorkspaces) {
                    Label("去工作区", systemImage: "folder")
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(tokens.accent)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: 420)
        .background(tokens.elevatedSurface.opacity(0.52), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tokens.border.opacity(0.58), lineWidth: 1)
        }
    }
}
