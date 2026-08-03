import ServiceManagement

struct ServiceManagementClient {
    var agentStatus: @MainActor () -> ServiceRegistrationState
    var agentConfigurationError: @MainActor () -> String?
    var isAgentRegistrationCurrent: @MainActor () -> Bool
    var markAgentRegistrationCurrent: @MainActor () -> Void
    var registerAgent: @MainActor () throws -> Void
    var unregisterAgent: @MainActor () async throws -> Void
    var mainAppStatus: @MainActor () -> ServiceRegistrationState
    var registerMainApp: @MainActor () throws -> Void
    var unregisterMainApp: @MainActor () async throws -> Void
    var openLoginItemsSettings: @MainActor () -> Void
}

extension ServiceManagementClient {
    @MainActor
    static var live: ServiceManagementClient {
        let registrationRevision = currentAgentRegistrationRevision()
        return ServiceManagementClient(
            agentStatus: {
                registrationState(for: agentService.status)
            },
            agentConfigurationError: {
                validateAgentConfiguration()
            },
            isAgentRegistrationCurrent: {
                guard let registrationRevision else { return true }
                return UserDefaults.standard.string(
                    forKey: agentRegistrationRevisionKey
                ) == registrationRevision
            },
            markAgentRegistrationCurrent: {
                guard let registrationRevision else { return }
                UserDefaults.standard.set(
                    registrationRevision,
                    forKey: agentRegistrationRevisionKey
                )
            },
            registerAgent: {
                let service = agentService
                if service.status != .enabled {
                    try service.register()
                }
            },
            unregisterAgent: {
                let service = agentService
                guard service.status != .notRegistered, service.status != .notFound else { return }
                // 使用异步 API 等待系统真正终止旧进程；回调完成后才可安全重新注册。
                try await service.unregister()
            },
            mainAppStatus: {
                registrationState(for: SMAppService.mainApp.status)
            },
            registerMainApp: {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            },
            unregisterMainApp: {
                guard SMAppService.mainApp.status != .notRegistered,
                      SMAppService.mainApp.status != .notFound
                else { return }
                try await SMAppService.mainApp.unregister()
            },
            openLoginItemsSettings: {
                SMAppService.openSystemSettingsLoginItems()
            }
        )
    }

    @MainActor
    private static var agentService: SMAppService {
        SMAppService.agent(plistName: agentPlistName)
    }

    private static let agentRegistrationRevisionKey =
        "MimiRemoteMac.agentRegistrationRevision"

    private static let agentPlistName = "com.gaixianggeng.mimi.mac.agentd.plist"

    /// `.notFound` 只表示 ServiceManagement 没找到服务记录，不能据此判断安装包漏文件。
    /// 这里直接核对包内 plist 与 BundleProgram，只有资源真的损坏时才要求重新安装。
    static func validateAgentConfiguration(
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> String? {
        let plistURL = bundleURL
            .appending(path: "Contents/Library/LaunchAgents", directoryHint: .isDirectory)
            .appending(path: agentPlistName, directoryHint: .notDirectory)
        guard fileManager.fileExists(atPath: plistURL.path) else {
            return "App 包内缺少 LaunchAgent 配置，请重新安装正式版本。"
        }
        guard let data = try? Data(contentsOf: plistURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let dictionary = propertyList as? [String: Any],
              let bundleProgram = dictionary["BundleProgram"] as? String,
              !bundleProgram.isEmpty
        else {
            return "App 包内的 LaunchAgent 配置无效，请重新安装正式版本。"
        }

        let executableURL = bundleURL.appending(path: bundleProgram, directoryHint: .notDirectory)
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            return "App 包内缺少可执行的 agentd，请重新安装正式版本。"
        }
        return nil
    }

    /// SMAppService 不会自动刷新已登记的 LaunchAgent 可执行文件。正式发布的
    /// build number 每次都会递增，因此用 App 版本与构建号识别需要重新注册的升级。
    private static func currentAgentRegistrationRevision(
        bundle: Bundle = .main
    ) -> String? {
        guard let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
              let build = bundle.object(
                  forInfoDictionaryKey: "CFBundleVersion"
              ) as? String,
              !version.isEmpty,
              !build.isEmpty
        else {
            return nil
        }
        return "\(version)+\(build)"
    }

    @MainActor
    private static func registrationState(for status: SMAppService.Status) -> ServiceRegistrationState {
        switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
}
