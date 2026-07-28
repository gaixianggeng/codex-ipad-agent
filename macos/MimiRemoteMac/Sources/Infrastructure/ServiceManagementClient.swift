import ServiceManagement

struct ServiceManagementClient {
    var agentStatus: @MainActor () -> ServiceRegistrationState
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
        SMAppService.agent(plistName: "com.gaixianggeng.mimi.mac.agentd.plist")
    }

    private static let agentRegistrationRevisionKey =
        "MimiRemoteMac.agentRegistrationRevision"

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
