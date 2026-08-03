import Foundation
import XCTest
@testable import MimiRemoteMac

@MainActor
final class HostStoreTests: XCTestCase {
    func testBootstrapRequiresSetupWhenConfigIsMissing() async {
        let store = makeStore(configExists: false)

        await store.bootstrap()

        XCTAssertEqual(store.lifecycle, .notConfigured)
        XCTAssertEqual(store.owner, .none)
    }

    func testBootstrapAutoEnablesClaudeAndReloadsRunningMacAgent() async {
        let events = EventRecorder()
        let registration = LaggingAgentRegistration()
        let store = makeStore(
            configExists: true,
            agentStatus: { registration.nextStatus() },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") },
            configureClaude: { preference, _ in
                events.append("configure-\(preference.rawValue)")
                return Self.claudeConfiguration(
                    enabled: true,
                    preference: .automatic,
                    previousEnabled: false,
                    previousPreference: .automatic,
                    changed: true,
                    restartRequired: true
                )
            },
            healthCheck: { _ in false }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, [
            "configure-auto", "unregister-mac", "register-mac",
        ])
        XCTAssertTrue(store.claudeEnabled)
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testDisablingClaudeReloadsServiceAndWaitsForDisabledRuntime() async {
        let events = EventRecorder()
        let disabledStatus = Self.statusWithClaude(enabled: false, state: .disabled)
        let store = makeStore(
            configExists: true,
            status: { disabledStatus },
            registerAgent: { events.append("register-mac") },
            configureClaude: { preference, restoreEnabled in
                events.append("configure-\(preference.rawValue)")
                if preference == .automatic {
                    return Self.claudeConfiguration(enabled: true, preference: .enabled)
                }
                return Self.claudeConfiguration(
                    enabled: restoreEnabled ?? false,
                    preference: preference,
                    previousEnabled: true,
                    previousPreference: .enabled,
                    changed: true,
                    restartRequired: true
                )
            }
        )
        await store.bootstrap()

        await store.setClaudeEnabled(false)

        XCTAssertEqual(events.values, [
            "configure-auto", "register-mac", "configure-disabled", "register-mac",
        ])
        XCTAssertFalse(store.claudeEnabled)
        XCTAssertNil(store.claudeError)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testClaudeServiceReloadFailureRestoresPreviousConfiguration() async {
        let events = EventRecorder()
        let registrations = CallCounter()
        let enabledStatus = Self.statusWithClaude(enabled: true, state: .connected)
        let store = makeStore(
            configExists: true,
            status: { enabledStatus },
            registerAgent: {
                let call = registrations.increment()
                events.append("register-\(call)")
                if call == 2 {
                    throw TestError.expected
                }
            },
            configureClaude: { preference, restoreEnabled in
                events.append("configure-\(preference.rawValue)-\(restoreEnabled.map(String.init) ?? "normal")")
                if preference == .automatic {
                    return Self.claudeConfiguration(enabled: true, preference: .enabled)
                }
                if let restoreEnabled {
                    return Self.claudeConfiguration(
                        enabled: restoreEnabled,
                        preference: preference,
                        previousEnabled: false,
                        previousPreference: .disabled,
                        changed: true,
                        restartRequired: true,
                        reason: "restored"
                    )
                }
                return Self.claudeConfiguration(
                    enabled: false,
                    preference: .disabled,
                    previousEnabled: true,
                    previousPreference: .enabled,
                    changed: true,
                    restartRequired: true
                )
            }
        )
        await store.bootstrap()

        await store.setClaudeEnabled(false)

        XCTAssertEqual(events.values, [
            "configure-auto-normal",
            "register-1",
            "configure-disabled-normal",
            "register-2",
            "configure-enabled-true",
            "register-3",
        ])
        XCTAssertTrue(store.claudeEnabled)
        XCTAssertTrue(store.claudeError?.contains("已恢复修改前") == true)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testBootstrapDetectsRunningHomebrewServiceWithoutChangingIt() async {
        let store = makeStore(configExists: true, homebrewLoaded: true)

        await store.bootstrap()

        XCTAssertEqual(store.lifecycle, .migrationRequired)
        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertTrue(store.homebrewLoaded)
    }

    func testTakeoverStopsHomebrewThenStartsBundledAgent() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            registerAgent: { events.append("register-mac") },
            homebrewStop: { events.append("stop-homebrew") }
        )
        await store.bootstrap()

        await store.takeOverHomebrew()

        XCTAssertEqual(events.values, ["stop-homebrew", "register-mac"])
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertNotNil(store.pairing)
    }

    func testFailedTakeoverRestoresHomebrewAutomatically() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            registerAgent: {
                events.append("register-mac")
                throw TestError.expected
            },
            unregisterAgent: { events.append("unregister-mac") },
            homebrewStart: { events.append("start-homebrew") },
            homebrewStop: { events.append("stop-homebrew") }
        )
        await store.bootstrap()

        await store.takeOverHomebrew()

        XCTAssertEqual(events.values, [
            "stop-homebrew", "register-mac", "unregister-mac", "start-homebrew",
        ])
        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertEqual(store.lifecycle, .migrationRequired)
        XCTAssertTrue(store.lastError?.contains("已恢复 Homebrew 服务") == true)
    }

    func testPairingFailureDoesNotRollBackSuccessfulTakeover() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            registerAgent: { events.append("register-mac") },
            homebrewStart: { events.append("start-homebrew") },
            homebrewStop: { events.append("stop-homebrew") },
            pair: { _ in throw TestError.expected }
        )
        await store.bootstrap()

        await store.takeOverHomebrew()

        XCTAssertEqual(events.values, ["stop-homebrew", "register-mac"])
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertTrue(store.lastError?.contains("服务接管成功") == true)
    }

    func testSelectingLANEnablesAccessRestartsOnceAndReturnsLANPairing() async {
        let events = EventRecorder()
        let lanPairing = PairingInfo(
            endpoint: "http://192.168.31.20:8787",
            pairURL: "mimiremote://pair?pair_sig=lan",
            expiresAt: "2026-07-22T12:00:00Z",
            warnings: ["仅限同一局域网"]
        )
        let store = makeStore(
            configExists: true,
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") },
            setLANAccess: { enabled in
                events.append("lan-\(enabled)")
                return NetworkConfigurationResult(
                    lanEnabled: enabled,
                    changed: true,
                    restartRequired: true
                )
            },
            pair: { network in
                events.append("pair-\(network.rawValue)")
                return network == .localNetwork ? lanPairing : Self.pairing
            },
            healthCheck: { _ in false }
        )
        await store.bootstrap()

        await store.refreshPairing(network: .localNetwork)

        XCTAssertEqual(events.values, [
            "pair-auto",
            "register-mac",
            "lan-true",
            "unregister-mac",
            "register-mac",
            "pair-lan",
        ])
        XCTAssertEqual(store.pairingNetwork, .localNetwork)
        XCTAssertEqual(store.pairing, lanPairing)
    }

    func testAutomaticPairingFallsBackToLANWhenTailscaleIsUnavailable() async {
        let events = EventRecorder()
        let lanPairing = PairingInfo(
            endpoint: "http://192.168.31.20:8787",
            network: .localNetwork,
            pairURL: "mimiremote://pair?pair_sig=automatic-lan",
            expiresAt: "2026-07-22T12:00:00Z",
            warnings: ["仅限同一局域网"]
        )
        let store = makeStore(
            configExists: true,
            registerAgent: { events.append("register-mac") },
            setLANAccess: { enabled in
                events.append("lan-\(enabled)")
                return NetworkConfigurationResult(
                    lanEnabled: enabled,
                    changed: false,
                    restartRequired: false
                )
            },
            pair: { network in
                events.append("pair-\(network.rawValue)")
                if network == .automatic {
                    throw TestError.expected
                }
                return lanPairing
            }
        )
        await store.bootstrap()

        await store.refreshPairing()

        XCTAssertEqual(store.pairingNetwork, .localNetwork)
        XCTAssertEqual(store.pairing, lanPairing)
        XCTAssertEqual(events.values, [
            "pair-auto", "lan-true", "register-mac",
            "pair-auto", "lan-true", "pair-lan",
        ])
    }

    func testDoctorKeepsHomebrewMigrationState() async {
        let store = makeStore(configExists: true, homebrewLoaded: true)
        await store.bootstrap()

        await store.runDoctor(fix: false)

        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertEqual(store.lifecycle, .migrationRequired)
    }

    func testFailedHomebrewRestoreReturnsToMacAgent() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") },
            homebrewStart: {
                events.append("start-homebrew")
                throw TestError.expected
            },
            homebrewStop: { events.append("stop-homebrew") },
            healthCheck: { _ in false }
        )
        await store.bootstrap()
        await store.takeOverHomebrew()

        await store.restoreHomebrew()

        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertTrue(store.lastError?.contains("已继续使用 App 服务") == true)
        XCTAssertEqual(events.values, [
            "stop-homebrew", "register-mac", "unregister-mac", "start-homebrew",
            "stop-homebrew", "register-mac",
        ])
    }

    func testRestartWaitsForAgentToFinishUnregisteringBeforeRegisteringAgain() async {
        let events = EventRecorder()
        let registration = LaggingAgentRegistration()
        let store = makeStore(
            configExists: true,
            agentStatus: { registration.nextStatus() },
            registerAgent: {
                // 模拟真实 SMAppService：状态仍为 enabled 时，registerAgent 会直接跳过。
                guard registration.nextStatus() != .enabled else { return }
                events.append("register-mac")
            },
            unregisterAgent: { events.append("unregister-mac") },
            healthCheck: { _ in
                events.append("health-stopped")
                return false
            }
        )
        await store.bootstrap()

        await store.restartService()

        XCTAssertEqual(events.values, [
            "unregister-mac", "health-stopped", "register-mac",
        ])
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.owner, .macApp)
    }

    func testStopAndQuitRequestSurvivesMenuDismissalAndWaitsForAgentShutdown() async {
        let events = EventRecorder()
        let terminated = expectation(description: "App terminates after agent shutdown")
        let store = makeStore(
            configExists: true,
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") },
            healthCheck: { _ in
                events.append("health-stopped")
                return false
            },
            terminateApplication: {
                events.append("terminate-app")
                terminated.fulfill()
            }
        )
        await store.bootstrap()

        store.requestStopServiceAndQuit()

        XCTAssertTrue(store.isBusy)
        XCTAssertTrue(store.isStoppingForQuit)
        await fulfillment(of: [terminated], timeout: 1)
        XCTAssertEqual(events.values, [
            "register-mac", "unregister-mac", "health-stopped", "terminate-app",
        ])
        XCTAssertEqual(store.lifecycle, .stopped)
        XCTAssertEqual(store.owner, .none)
    }

    func testBootstrapReplacesOutdatedBundledAgentBeforeReportingReady() async {
        let events = EventRecorder()
        let registration = LaggingAgentRegistration()
        let outdated = AgentStatus(
            processOK: true,
            serviceOK: false,
            processError: nil,
            serviceError: "运行中的 agentd 仍是旧构建",
            version: "0.1.5+mac.240",
            serverVersion: "0.1.5+mac.239",
            endpoint: Self.readyStatus.endpoint,
            configPath: Self.readyStatus.configPath,
            projects: Self.readyStatus.projects,
            doctorOK: false,
            doctor: Self.readyStatus.doctor,
            pairExpires: nil
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { registration.nextStatus() },
            status: {
                events.values.contains("register-mac") ? Self.readyStatus : outdated
            },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") },
            healthCheck: { _ in
                events.append("health-stopped")
                return false
            }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, [
            "unregister-mac", "health-stopped", "register-mac",
        ])
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.owner, .macApp)
    }

    func testBootstrapReregistersEnabledAgentWhenRegistrationRevisionIsStale() async {
        let events = EventRecorder()
        let registration = LaggingAgentRegistration()
        let store = makeStore(
            configExists: true,
            agentStatus: { registration.nextStatus() },
            isAgentRegistrationCurrent: { false },
            markAgentRegistrationCurrent: { events.append("mark-registration") },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, [
            "unregister-mac", "register-mac", "mark-registration",
        ])
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.owner, .macApp)
    }

    func testBootstrapReusesEnabledAgentWhenRegistrationRevisionIsCurrent() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            isAgentRegistrationCurrent: { true },
            markAgentRegistrationCurrent: { events.append("mark-registration") },
            status: {
                events.append("status")
                return Self.readyStatus
            },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["status"])
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.owner, .macApp)
    }

    func testMenuAppearanceReusesRecentBootstrapStatus() async {
        let events = EventRecorder()
        let current = AgentStatus(
            processOK: Self.readyStatus.processOK,
            serviceOK: Self.readyStatus.serviceOK,
            processError: Self.readyStatus.processError,
            serviceError: Self.readyStatus.serviceError,
            version: Self.readyStatus.version,
            serverVersion: Self.readyStatus.serverVersion,
            endpoint: Self.readyStatus.endpoint,
            configPath: Self.readyStatus.configPath,
            projects: Self.readyStatus.projects,
            doctorOK: Self.readyStatus.doctorOK,
            doctor: Self.readyStatus.doctor,
            pairExpires: Self.readyStatus.pairExpires,
            runtimeStatus: AgentRuntimeStatusSnapshot(
                checkedAt: "2026-07-28T02:00:00Z",
                runtimes: [],
                refreshing: false,
                stale: false
            )
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: {
                events.append("status")
                return current
            }
        )

        await store.bootstrap()
        await store.refreshIfNeeded()

        XCTAssertEqual(events.values, ["status"])
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testTransientMissingRuntimeStatusPreservesPreviousSnapshotAsStale() async {
        let events = EventRecorder()
        let snapshot = AgentRuntimeStatusSnapshot(
            checkedAt: "2026-07-28T02:00:00Z",
            runtimes: [
                AgentRuntimeStatus(
                    id: "codex",
                    title: "Codex",
                    enabled: true,
                    state: .connected,
                    authMode: "chatgpt",
                    planType: "pro",
                    reason: nil,
                    rateLimits: nil
                ),
            ],
            refreshing: false,
            stale: false
        )
        let statusWithRuntime = AgentStatus(
            processOK: Self.readyStatus.processOK,
            serviceOK: Self.readyStatus.serviceOK,
            processError: Self.readyStatus.processError,
            serviceError: Self.readyStatus.serviceError,
            version: Self.readyStatus.version,
            serverVersion: Self.readyStatus.serverVersion,
            endpoint: Self.readyStatus.endpoint,
            configPath: Self.readyStatus.configPath,
            projects: Self.readyStatus.projects,
            doctorOK: Self.readyStatus.doctorOK,
            doctor: Self.readyStatus.doctor,
            pairExpires: Self.readyStatus.pairExpires,
            runtimeStatus: snapshot
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: {
                events.append("status")
                return events.values.count == 1 ? statusWithRuntime : Self.readyStatus
            }
        )

        await store.bootstrap()
        await store.refresh()

        XCTAssertEqual(events.values, ["status", "status"])
        XCTAssertEqual(store.status?.runtimeStatus?.runtimes.map(\.id), ["codex"])
        XCTAssertEqual(store.status?.runtimeStatus?.stale, true)
    }

    private func makeStore(
        configExists: Bool,
        homebrewLoaded: Bool = false,
        agentStatus: @escaping @MainActor () -> ServiceRegistrationState = { .notRegistered },
        isAgentRegistrationCurrent: @escaping @MainActor () -> Bool = { true },
        markAgentRegistrationCurrent: @escaping @MainActor () -> Void = {},
        status: @escaping @Sendable () async throws -> AgentStatus = {
            HostStoreTests.readyStatus
        },
        registerAgent: @escaping @MainActor () throws -> Void = {},
        unregisterAgent: @escaping @MainActor () async throws -> Void = {},
        homebrewStart: @escaping @Sendable () async throws -> Void = {},
        homebrewStop: @escaping @Sendable () async throws -> Void = {},
        configureClaude: @escaping @Sendable (
            ClaudeActivationPreference,
            Bool?
        ) async throws -> ClaudeConfigurationResult = { preference, restoreEnabled in
            HostStoreTests.claudeConfiguration(
                enabled: restoreEnabled ?? false,
                preference: preference,
                previousEnabled: false,
                previousPreference: .automatic
            )
        },
        setLANAccess: @escaping @Sendable (Bool) async throws -> NetworkConfigurationResult = {
            NetworkConfigurationResult(lanEnabled: $0, changed: false, restartRequired: false)
        },
        pair: (@Sendable (PairingNetwork) async throws -> PairingInfo)? = nil,
        healthCheck: @escaping @Sendable (String) async -> Bool = { _ in true },
        terminateApplication: @escaping @MainActor () -> Void = {}
    ) -> HostStore {
        let readyStatus = Self.readyStatus
        let doctor = readyStatus.doctor
        let agent = AgentCommandClient(
            configExists: { configExists },
            setup: { _ in Self.pairing },
            status: status,
            statusAt: { _ in readyStatus },
            doctor: { _ in DoctorFixResults(fixes: [], results: doctor) },
            configureClaude: configureClaude,
            setLANAccess: setLANAccess,
            pair: pair ?? { _ in Self.pairing },
            version: { readyStatus.version }
        )
        let services = ServiceManagementClient(
            agentStatus: agentStatus,
            isAgentRegistrationCurrent: isAgentRegistrationCurrent,
            markAgentRegistrationCurrent: markAgentRegistrationCurrent,
            registerAgent: registerAgent,
            unregisterAgent: unregisterAgent,
            mainAppStatus: { .enabled },
            registerMainApp: {},
            unregisterMainApp: {},
            openLoginItemsSettings: {}
        )
        let homebrew = HomebrewServiceClient(
            isLoaded: { homebrewLoaded },
            installedAgentBinary: { URL(filePath: "/opt/homebrew/bin/agentd") },
            start: homebrewStart,
            stop: homebrewStop
        )
        return HostStore(
            agent: agent,
            services: services,
            homebrew: homebrew,
            health: HealthClient(check: healthCheck, checkDirect: { _ in true }),
            logs: AgentLogClient(
                recentLines: { _ in [] },
                reveal: {},
                fileURL: URL(filePath: "/tmp/mimi-remote-agentd-test.log")
            ),
            terminateApplication: terminateApplication
        )
    }

    private nonisolated static let pairing = PairingInfo(
        endpoint: "http://127.0.0.1:8787",
        pairURL: "mimiremote://pair?pair_sig=test",
        expiresAt: "2026-07-22T12:00:00Z",
        warnings: []
    )

    private nonisolated static let readyStatus: AgentStatus = {
        let doctor = AgentDoctorResults(
            ok: true,
            version: "0.1.0",
            listen: "127.0.0.1:8787",
            checks: []
        )
        return AgentStatus(
            processOK: true,
            serviceOK: true,
            processError: nil,
            serviceError: nil,
            version: "0.1.0",
            endpoint: "http://127.0.0.1:8787",
            configPath: "/tmp/config.json",
            projects: 1,
            doctorOK: true,
            doctor: doctor,
            pairExpires: nil
        )
    }()

    private nonisolated static func statusWithClaude(
        enabled: Bool,
        state: AgentRuntimeConnectionState
    ) -> AgentStatus {
        AgentStatus(
            processOK: readyStatus.processOK,
            serviceOK: readyStatus.serviceOK,
            processError: readyStatus.processError,
            serviceError: readyStatus.serviceError,
            version: readyStatus.version,
            endpoint: readyStatus.endpoint,
            configPath: readyStatus.configPath,
            projects: readyStatus.projects,
            doctorOK: readyStatus.doctorOK,
            doctor: readyStatus.doctor,
            pairExpires: nil,
            runtimeStatus: AgentRuntimeStatusSnapshot(
                checkedAt: "2026-08-03T03:00:00Z",
                runtimes: [
                    AgentRuntimeStatus(
                        id: "claude",
                        title: "Claude",
                        enabled: enabled,
                        state: state,
                        authMode: enabled ? "oauth" : nil,
                        planType: enabled ? "pro" : nil,
                        reason: enabled ? nil : "disabled",
                        rateLimits: nil
                    ),
                ]
            )
        )
    }

    private nonisolated static func claudeConfiguration(
        enabled: Bool,
        preference: ClaudeActivationPreference,
        previousEnabled: Bool = false,
        previousPreference: ClaudeActivationPreference = .automatic,
        changed: Bool = false,
        restartRequired: Bool = false,
        reason: String? = nil
    ) -> ClaudeConfigurationResult {
        ClaudeConfigurationResult(
            enabled: enabled,
            available: enabled,
            preference: preference,
            previousEnabled: previousEnabled,
            previousPreference: previousPreference,
            changed: changed,
            restartRequired: restartRequired,
            reason: reason ?? (enabled ? "ready" : "disabled_by_user"),
            message: enabled
                ? "已检测到 Claude Code 和兼容的 Claude bridge。"
                : "Claude 实验通道已关闭。"
        )
    }
}

@MainActor
private final class LaggingAgentRegistration {
    private var statusChecks = 0

    func nextStatus() -> ServiceRegistrationState {
        statusChecks += 1
        // bootstrap 读取两次；重启后的第一次读取仍返回 enabled，随后才完成注销。
        return statusChecks <= 3 ? .enabled : .notRegistered
    }
}

private enum TestError: LocalizedError {
    case expected

    var errorDescription: String? { "预期的测试错误" }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
