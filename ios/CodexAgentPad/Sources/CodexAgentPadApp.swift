import SwiftUI

@main
struct CodexAgentPadApp: App {
    @StateObject private var appStore: AppStore
    @StateObject private var conversationStore: ConversationStore
    @StateObject private var logStore: LogStore
    @StateObject private var sessionStore: SessionStore

    init() {
        let appStore = AppStore()
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        _appStore = StateObject(wrappedValue: appStore)
        _conversationStore = StateObject(wrappedValue: conversationStore)
        _logStore = StateObject(wrappedValue: logStore)
        _sessionStore = StateObject(wrappedValue: SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: logStore
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appStore)
                .environmentObject(sessionStore)
                .environmentObject(conversationStore)
                .environmentObject(logStore)
        }
    }
}
