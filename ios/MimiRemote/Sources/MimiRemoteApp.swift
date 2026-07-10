import SwiftUI

@main
struct MimiRemoteApp: App {
    @StateObject private var appStore: AppStore
    @StateObject private var conversationStore: ConversationStore
    @StateObject private var logStore: LogStore
    @StateObject private var contextStore: SessionContextStore
    @StateObject private var sessionStore: SessionStore
    @StateObject private var themeStore: ThemeStore

    init() {
        let appStore = AppStore()
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        let contextStore = SessionContextStore()
        let themeStore = ThemeStore()
        _appStore = StateObject(wrappedValue: appStore)
        _conversationStore = StateObject(wrappedValue: conversationStore)
        _logStore = StateObject(wrappedValue: logStore)
        _contextStore = StateObject(wrappedValue: contextStore)
        _themeStore = StateObject(wrappedValue: themeStore)
        _sessionStore = StateObject(wrappedValue: SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: logStore,
            contextStore: contextStore
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appStore)
                .environmentObject(sessionStore)
                .environmentObject(conversationStore)
                .environmentObject(logStore)
                .environmentObject(contextStore)
                .environmentObject(themeStore)
                .onOpenURL { url in
                    Task { @MainActor in
                        do {
                            _ = try await sessionStore.applyPairingURL(url)
                            await sessionStore.refreshAll(autoAttach: true)
                        } catch {
                            appStore.connectionStatus = .failed(error.localizedDescription)
                            appStore.lastError = error.localizedDescription
                        }
                    }
                }
        }
    }
}
