import Foundation

struct RecentWorkspaceStore {
    private typealias Storage = ProfileScopedStorage<[AgentWorkspace]>

    private let defaults: UserDefaults
    private let key: String
    private let limit: Int

    init(defaults: UserDefaults = .standard, key: String = "agentd.recentWorkspaces", limit: Int = 24) {
        self.defaults = defaults
        self.key = key
        self.limit = max(1, limit)
    }

    func load(endpoint: String) -> [AgentWorkspace] {
        storage().byEndpoint[normalizedEndpoint(endpoint)]?
            .sorted(by: Self.workspaceSort)
            ?? []
    }

    func save(_ workspaces: [AgentWorkspace], endpoint: String) {
        var storage = storage()
        storage.byEndpoint[normalizedEndpoint(endpoint)] = bounded(workspaces)
        persist(storage)
    }

    func load(
        profileID: String,
        legacyEndpoint: String,
        profiles: [ConnectionProfile]
    ) -> [AgentWorkspace] {
        var storage = storage()
        let didMigrate = storage.migrateLegacyValueIfUnique(
            profileID: profileID,
            endpoint: legacyEndpoint,
            profiles: profiles
        )
        if didMigrate {
            persist(storage)
        }
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return []
        }
        if let workspaces = storage.byProfileID[profileKey] {
            return workspaces.sorted(by: Self.workspaceSort)
        }
        // 测试、调试和迁移失败后的单连接可以继续只读旧值；只有唯一 Profile 才会持久化复制。
        if profiles.isEmpty {
            return storage.byEndpoint[normalizedEndpoint(legacyEndpoint)]?
                .sorted(by: Self.workspaceSort)
                ?? []
        }
        return []
    }

    func load(profileID: String) -> [AgentWorkspace] {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return []
        }
        return storage().byProfileID[profileKey]?
            .sorted(by: Self.workspaceSort)
            ?? []
    }

    func save(_ workspaces: [AgentWorkspace], profileID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var storage = storage()
        storage.byProfileID[profileKey] = bounded(workspaces)
        persist(storage)
    }

    func upsert(_ workspace: AgentWorkspace, endpoint: String, openedAt: Date = Date()) -> [AgentWorkspace] {
        var items = load(endpoint: endpoint)
        items.removeAll { $0.id == workspace.id }
        items.insert(workspace.opened(at: openedAt), at: 0)
        let next = bounded(items)
        save(next, endpoint: endpoint)
        return next
    }

    func upsert(
        _ workspace: AgentWorkspace,
        profileID: String,
        openedAt: Date = Date()
    ) -> [AgentWorkspace] {
        var items = load(profileID: profileID)
        items.removeAll { $0.id == workspace.id }
        items.insert(workspace.opened(at: openedAt), at: 0)
        let next = bounded(items)
        save(next, profileID: profileID)
        return next
    }

    func forget(id: String, endpoint: String) -> [AgentWorkspace] {
        let next = load(endpoint: endpoint).filter { $0.id != id }
        save(next, endpoint: endpoint)
        return next
    }

    func forget(id: String, profileID: String) -> [AgentWorkspace] {
        let next = load(profileID: profileID).filter { $0.id != id }
        save(next, profileID: profileID)
        return next
    }

    func remove(profileID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var storage = storage()
        guard storage.byProfileID.removeValue(forKey: profileKey) != nil else {
            return
        }
        persist(storage)
    }

    private func bounded(_ workspaces: [AgentWorkspace]) -> [AgentWorkspace] {
        Array(workspaces.sorted(by: Self.workspaceSort).prefix(limit))
    }

    private static func workspaceSort(lhs: AgentWorkspace, rhs: AgentWorkspace) -> Bool {
        let left = lhs.lastOpenedAt ?? .distantPast
        let right = rhs.lastOpenedAt ?? .distantPast
        if left == right {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return left > right
    }

    private func storage() -> Storage {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            return Storage()
        }
        return decoded
    }

    private func persist(_ storage: Storage) {
        guard let data = try? JSONEncoder().encode(storage) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private func normalizedEndpoint(_ endpoint: String) -> String {
        AgentAPIClient.normalizedEndpoint(endpoint)
    }
}
