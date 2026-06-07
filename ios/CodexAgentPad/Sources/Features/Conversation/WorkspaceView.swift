import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if sessionStore.selectedProjectID == nil && sessionStore.selectedSessionID == nil {
                ContentUnavailableView(
                    "打开工作区",
                    systemImage: "folder.badge.plus",
                    description: Text("从左侧打开一个 Mac 工作目录后，可以查看会话或新建任务。")
                )
                .font(themeStore.uiFont(.callout))
                .foregroundStyle(tokens.secondaryText)
            } else {
                ConversationView()
            }
        }
        .background(tokens.background)
    }
}
