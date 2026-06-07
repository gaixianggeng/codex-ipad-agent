import Foundation

struct RecentWorkspaceStore {
    private struct Storage: Codable {
        var byEndpoint: [String: [AgentWorkspace]] = [:]
    }

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

    func upsert(_ workspace: AgentWorkspace, endpoint: String, openedAt: Date = Date()) -> [AgentWorkspace] {
        var items = load(endpoint: endpoint)
        items.removeAll { $0.id == workspace.id }
        items.insert(workspace.opened(at: openedAt), at: 0)
        let next = bounded(items)
        save(next, endpoint: endpoint)
        return next
    }

    func forget(id: String, endpoint: String) -> [AgentWorkspace] {
        let next = load(endpoint: endpoint).filter { $0.id != id }
        save(next, endpoint: endpoint)
        return next
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
