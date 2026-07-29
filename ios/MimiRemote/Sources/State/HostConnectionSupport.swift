import Foundation
import os

struct PreparedHostLease: Equatable {
    let endpoint: String
    let installationID: String
    let profileTarget: PreparedConnectionProfileTarget
    let profileRevision: UInt64?
    let tokenFingerprint: String
}

enum HostCredentialWriteReceipt: Sendable {
    case unchanged
    case inserted
    case replaced(previousToken: String)
}

/// Keychain 访问串行化到独立 actor。主线程只提交/接收短字符串，不直接参与非当前主机探活的读取。
actor HostCredentialVault {
    private let tokenStore: TokenStore
    private var memoryTokens: [String: String] = [:]

    init(tokenStore: TokenStore) {
        self.tokenStore = tokenStore
    }

    func token(for profileID: String) throws -> String {
        if let cached = memoryTokens[profileID] {
            return cached
        }
        let token = try tokenStore.load(profileID: profileID)
        memoryTokens[profileID] = token
        return token
    }

    /// Keychain 写入与内存缓存必须由同一个 actor 串行提交，避免切换成功后
    /// 一个迟到的 remember/remove Task 把另一台 Mac 的凭据缓存覆盖掉。
    func save(
        _ token: String,
        for profileID: String,
        forcePersistence: Bool = false
    ) throws -> HostCredentialWriteReceipt {
        if !forcePersistence, memoryTokens[profileID] == token {
            // 快速切换读取过目标 Profile 的 Token；未变化时无需再次触发 Keychain I/O。
            return .unchanged
        }
        let previousToken: String
        if !forcePersistence, let cached = memoryTokens[profileID] {
            previousToken = cached
        } else {
            // 临时 loopback 档案转为远端连接时必须重新读取 Keychain，
            // 不能把仅存在于内存的 Token 误判为已经持久化。
            previousToken = try tokenStore.load(profileID: profileID)
        }
        if previousToken == token {
            memoryTokens[profileID] = token
            return .unchanged
        }
        try tokenStore.save(token, profileID: profileID)
        memoryTokens[profileID] = token
        return previousToken.isEmpty ? .inserted : .replaced(previousToken: previousToken)
    }

    /// 未签入 Catalyst provisioning profile 的本地 Debug 包无法访问数据保护 Keychain。
    /// loopback 自动配对可以安全地只保留进程内凭据，重启后再向同机 agentd 领取。
    func rememberInMemory(_ token: String, for profileID: String) -> HostCredentialWriteReceipt {
        guard let previousToken = memoryTokens.updateValue(token, forKey: profileID) else {
            return .inserted
        }
        return previousToken == token ? .unchanged : .replaced(previousToken: previousToken)
    }

    func rollbackMemory(_ receipt: HostCredentialWriteReceipt, profileID: String) {
        switch receipt {
        case .unchanged:
            return
        case .inserted:
            memoryTokens.removeValue(forKey: profileID)
        case .replaced(let previousToken):
            memoryTokens[profileID] = previousToken
        }
    }

    func forgetMemory(profileID: String) {
        memoryTokens.removeValue(forKey: profileID)
    }

    func rollback(_ receipt: HostCredentialWriteReceipt, profileID: String) throws {
        switch receipt {
        case .unchanged:
            return
        case .inserted:
            try tokenStore.delete(profileID: profileID, allowMissing: true)
            memoryTokens.removeValue(forKey: profileID)
        case .replaced(let previousToken):
            try tokenStore.save(previousToken, profileID: profileID)
            memoryTokens[profileID] = previousToken
        }
    }

    func delete(profileID: String, allowMissing: Bool = true) throws {
        try tokenStore.delete(profileID: profileID, allowMissing: allowMissing)
        memoryTokens.removeValue(forKey: profileID)
    }

    func deleteLegacy(allowMissing: Bool = true) throws {
        try tokenStore.delete(allowMissing: allowMissing)
    }

    func clearMemory() {
        memoryTokens.removeAll(keepingCapacity: false)
    }
}

@MainActor
final class PreparedHostContext {
    let lease: PreparedHostLease
    let expiresAt: Date

    private var runtimeBundle: AppServerRuntimeBundle?
    private var expirationTask: Task<Void, Never>?

    init(
        lease: PreparedHostLease,
        runtimeBundle: AppServerRuntimeBundle,
        expiresAt: Date
    ) {
        self.lease = lease
        self.runtimeBundle = runtimeBundle
        self.expiresAt = expiresAt
        // Task 强持有 context 到 deadline；即使调用方直接丢弃 PreparedConnectionSettings，
        // 候选 Runtime 也会在 8 秒内显式 shutdown，而不是只依赖 deinit。
        expirationTask = Task { [self] in
            let delay = max(0, expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await discard()
        }
    }

    deinit {
        expirationTask?.cancel()
    }

    var isConsumed: Bool {
        runtimeBundle == nil
    }

    func validatedRuntimeBundle(
        matching expectedLease: PreparedHostLease,
        now: Date = Date()
    ) throws -> AppServerRuntimeBundle {
        guard now <= expiresAt else {
            throw ConnectionProfileError.preparedContextExpired
        }
        guard lease == expectedLease else {
            throw ConnectionProfileError.preparedContextMismatch
        }
        guard let runtimeBundle else {
            throw ConnectionProfileError.preparedContextConsumed
        }
        return runtimeBundle
    }

    func markConsumed() {
        expirationTask?.cancel()
        expirationTask = nil
        runtimeBundle = nil
    }

    func discard() async {
        guard let runtimeBundle else {
            return
        }
        expirationTask?.cancel()
        expirationTask = nil
        self.runtimeBundle = nil
        await runtimeBundle.shutdownForHostSwitch()
    }
}

struct HostProbeDescriptor {
    let profileID: String
    let profileRevision: UInt64
    let endpoint: String
    let token: String
    let expectedInstallationID: String?
}

enum HostSwitchSignpost {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gaixianggeng.mimi",
        category: "HostSwitch"
    )

    static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }

    static func begin(_ name: StaticString) {
        os_signpost(.begin, log: log, name: name)
    }

    static func end(_ name: StaticString) {
        os_signpost(.end, log: log, name: name)
    }
}
