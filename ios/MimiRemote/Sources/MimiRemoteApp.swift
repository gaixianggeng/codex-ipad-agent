import SwiftUI
import UserNotifications

/// 本地通知只携带路由元数据，不携带 Token、消息正文或工作目录。
/// version 用于拒绝未来不兼容或旧版无边界的 payload。
struct SessionNotificationRoute: Equatable, Hashable {
    static let currentVersion = 1

    let version: Int
    let profileID: String
    let projectID: String
    let sessionID: SessionID

    private enum Key {
        static let version = "mimi.route.version"
        static let profileID = "mimi.route.profileID"
        static let projectID = "mimi.route.projectID"
        static let sessionID = "mimi.route.sessionID"
    }

    static func current(profileID: String, projectID: String, sessionID: SessionID) -> SessionNotificationRoute {
        SessionNotificationRoute(
            version: currentVersion,
            profileID: profileID,
            projectID: projectID,
            sessionID: sessionID
        )
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let version = userInfo[Key.version] as? Int,
              version == Self.currentVersion,
              let profileID = Self.normalizedIdentifier(userInfo[Key.profileID]),
              let projectID = Self.normalizedIdentifier(userInfo[Key.projectID]),
              let sessionID = Self.normalizedIdentifier(userInfo[Key.sessionID])
        else {
            return nil
        }
        self.version = version
        self.profileID = profileID
        self.projectID = projectID
        self.sessionID = sessionID
    }

    var userInfo: [AnyHashable: Any] {
        [
            Key.version: version,
            Key.profileID: profileID,
            Key.projectID: projectID,
            Key.sessionID: sessionID
        ]
    }

    private init(version: Int, profileID: String, projectID: String, sessionID: SessionID) {
        self.version = version
        self.profileID = profileID
        self.projectID = projectID
        self.sessionID = sessionID
    }

    private static func normalizedIdentifier(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // 通知路由不是自由文本；限制长度可避免畸形 payload 被带入请求路径。
        guard !trimmed.isEmpty, trimmed.count <= 512 else { return nil }
        return trimmed
    }
}

/// UNUserNotificationCenter 的薄适配层：系统回调只负责严格解码并入队，业务选择在 RootView 中执行。
/// pendingRoute 让冷启动时“通知先到、SwiftUI 后建立”也不会丢失点击。
@MainActor
final class SessionNotificationResponseAdapter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var pendingRoute: SessionNotificationRoute?

    @discardableResult
    func receive(userInfo: [AnyHashable: Any]) -> Bool {
        guard let route = SessionNotificationRoute(userInfo: userInfo) else {
            return false
        }
        pendingRoute = route
        return true
    }

    func consume(_ route: SessionNotificationRoute) {
        guard pendingRoute == route else { return }
        pendingRoute = nil
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor [weak self] in
            _ = self?.receive(userInfo: userInfo)
        }
        // 系统回调不等待网络或会话加载，避免通知点击处理超时。
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 前台仍展示通知，但只有用户明确点击后才进入 didReceive 路由。
        completionHandler([.banner, .sound])
    }
}

@main
struct MimiRemoteApp: App {
    @AppStorage(AppLanguage.preferenceKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @StateObject private var appStore: AppStore
    @StateObject private var conversationStore: ConversationStore
    @StateObject private var logStore: LogStore
    @StateObject private var contextStore: SessionContextStore
    @StateObject private var sessionStore: SessionStore
    @StateObject private var themeStore: ThemeStore
    @StateObject private var notificationResponseAdapter: SessionNotificationResponseAdapter

    init() {
        let appStore = AppStore()
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        let contextStore = SessionContextStore()
        let themeStore = ThemeStore()
        let notificationResponseAdapter = SessionNotificationResponseAdapter()
        _appStore = StateObject(wrappedValue: appStore)
        _conversationStore = StateObject(wrappedValue: conversationStore)
        _logStore = StateObject(wrappedValue: logStore)
        _contextStore = StateObject(wrappedValue: contextStore)
        _themeStore = StateObject(wrappedValue: themeStore)
        _notificationResponseAdapter = StateObject(wrappedValue: notificationResponseAdapter)
        _sessionStore = StateObject(wrappedValue: SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: logStore,
            contextStore: contextStore
        ))
        // 尽早注册 delegate；冷启动点击会先进入 adapter 的 pendingRoute，等 RootView 消费。
        UNUserNotificationCenter.current().delegate = notificationResponseAdapter
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // locale 变化会让整个 SwiftUI 视图树重新求值，现有 L10n 调用即可即时换语言。
                .environment(\.locale, selectedAppLanguage.locale)
                .environmentObject(appStore)
                .environmentObject(sessionStore)
                .environmentObject(conversationStore)
                .environmentObject(logStore)
                .environmentObject(contextStore)
                .environmentObject(themeStore)
                .environmentObject(notificationResponseAdapter)
                .onOpenURL { url in
                    Task { @MainActor in
                        do {
                            let wasConfigured = appStore.isConfigured
                            _ = try await sessionStore.applyPairingURL(url)
                            // 首次 URL 配对要覆盖 Tailscale / gateway 冷启动窗口；已有档案修复只做短等待。
                            _ = await sessionStore.refreshAfterConnectionCommit(
                                maxWait: wasConfigured ? 10 : 45
                            )
                        } catch {
                            appStore.connectionStatus = .failed(error.localizedDescription)
                            appStore.lastError = error.localizedDescription
                        }
                    }
                }
        }
    }

    private var selectedAppLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRawValue) ?? .system
    }
}
