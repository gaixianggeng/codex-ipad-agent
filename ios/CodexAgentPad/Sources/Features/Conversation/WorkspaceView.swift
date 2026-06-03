import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    var body: some View {
        Group {
            if sessionStore.selectedProjectID == nil && sessionStore.selectedSessionID == nil {
                ContentUnavailableView(
                    "请选择项目",
                    systemImage: "folder",
                    description: Text("选择项目后可以查看历史会话或新建任务。")
                )
            } else {
                ConversationView()
            }
        }
    }
}
