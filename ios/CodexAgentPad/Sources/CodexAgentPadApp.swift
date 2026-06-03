import SwiftUI

@main
struct CodexAgentPadApp: App {
    @StateObject private var appStore: AppStore
    @StateObject private var conversationStore: ConversationStore
    @StateObject private var logStore: LogStore
    @StateObject private var terminalStore: TerminalSurfaceStore
    @StateObject private var sessionStore: SessionStore

    init() {
        let appStore = AppStore()
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        let terminalStore = TerminalSurfaceStore()
        _appStore = StateObject(wrappedValue: appStore)
        _conversationStore = StateObject(wrappedValue: conversationStore)
        _logStore = StateObject(wrappedValue: logStore)
        _terminalStore = StateObject(wrappedValue: terminalStore)
        _sessionStore = StateObject(wrappedValue: SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: logStore,
            terminalStore: terminalStore
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appStore)
                .environmentObject(sessionStore)
                .environmentObject(conversationStore)
                .environmentObject(logStore)
                .environmentObject(terminalStore)
        }
    }
}
