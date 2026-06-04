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
                    "请选择项目",
                    systemImage: "folder",
                    description: Text("选择项目后可以查看历史会话或新建任务。")
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
