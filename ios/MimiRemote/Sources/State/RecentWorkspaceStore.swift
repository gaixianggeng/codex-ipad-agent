import Foundation

struct RecentWorkspaceReconciliation: Equatable {
    let workspaces: [AgentWorkspace]
    let replacedWorkspaceIDs: [String: String]

    static var empty: RecentWorkspaceReconciliation {
        RecentWorkspaceReconciliation(
            workspaces: [],
            replacedWorkspaceIDs: [:]
        )
    }
}

enum WorkspacePathIdentity {
    /// 工作区路径属于远端 Mac，不能在 iPad 上调用 resolvingSymlinksInPath。
    /// 这里只做不会访问本地文件系统的词法归一化；符号链接等价关系由 agentd resolve
    /// 返回的 canonical path 与本次用户输入路径共同补充。
    static func normalizedPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        guard trimmed.hasPrefix("/") else {
            return normalizedNonPOSIXPath(trimmed)
        }

        var components: [Substring] = []
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                }
            default:
                components.append(component)
            }
        }

        var path = "/" + components.joined(separator: "/")
        // macOS 上 /var、/tmp、/etc 是 /private 下目录的系统级别名。agentd realpath
        // 返回 /private/...，旧客户端缓存则可能仍保存短路径，需要在离线迁移时视为同一目录。
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            path = "/private" + path
            break
        }
        return path
    }

    private static func normalizedNonPOSIXPath(_ rawPath: String) -> String {
        var path = rawPath
        while path.count > 1, path.last == "/" || path.last == "\\" {
            path.removeLast()
        }
        return path
    }
}

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
        loadReconciled(endpoint: endpoint).workspaces
    }

    func loadReconciled(endpoint: String) -> RecentWorkspaceReconciliation {
        var storage = storage()
        let endpointKey = normalizedEndpoint(endpoint)
        guard let stored = storage.byEndpoint[endpointKey] else {
            return .empty
        }
        let reconciliation = boundedReconciliation(stored)
        if stored != reconciliation.workspaces {
            storage.byEndpoint[endpointKey] = reconciliation.workspaces
            persist(storage)
        }
        return reconciliation
    }

    func save(_ workspaces: [AgentWorkspace], endpoint: String) {
        _ = saveReconciled(workspaces, endpoint: endpoint)
    }

    @discardableResult
    func saveReconciled(
        _ workspaces: [AgentWorkspace],
        endpoint: String
    ) -> RecentWorkspaceReconciliation {
        var storage = storage()
        let reconciliation = boundedReconciliation(workspaces)
        storage.byEndpoint[normalizedEndpoint(endpoint)] = reconciliation.workspaces
        persist(storage)
        return reconciliation
    }

    func load(
        profileID: String,
        legacyEndpoint: String,
        profiles: [ConnectionProfile]
    ) -> [AgentWorkspace] {
        loadReconciled(
            profileID: profileID,
            legacyEndpoint: legacyEndpoint,
            profiles: profiles
        ).workspaces
    }

    func loadReconciled(
        profileID: String,
        legacyEndpoint: String,
        profiles: [ConnectionProfile]
    ) -> RecentWorkspaceReconciliation {
        var storage = storage()
        let didMigrate = storage.migrateLegacyValueIfUnique(
            profileID: profileID,
            endpoint: legacyEndpoint,
            profiles: profiles
        )
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return .empty
        }
        if let workspaces = storage.byProfileID[profileKey] {
            let reconciliation = boundedReconciliation(workspaces)
            if didMigrate || workspaces != reconciliation.workspaces {
                storage.byProfileID[profileKey] = reconciliation.workspaces
                persist(storage)
            }
            return reconciliation
        }
        // 测试、调试和迁移失败后的单连接可以继续只读旧值；只有唯一 Profile 才会持久化复制。
        if profiles.isEmpty {
            guard let legacy = storage.byEndpoint[normalizedEndpoint(legacyEndpoint)] else {
                return .empty
            }
            return boundedReconciliation(legacy)
        }
        if didMigrate {
            persist(storage)
        }
        return .empty
    }

    func load(profileID: String) -> [AgentWorkspace] {
        loadReconciled(profileID: profileID).workspaces
    }

    func loadReconciled(profileID: String) -> RecentWorkspaceReconciliation {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return .empty
        }
        var storage = storage()
        guard let stored = storage.byProfileID[profileKey] else {
            return .empty
        }
        let reconciliation = boundedReconciliation(stored)
        if stored != reconciliation.workspaces {
            storage.byProfileID[profileKey] = reconciliation.workspaces
            persist(storage)
        }
        return reconciliation
    }

    func save(_ workspaces: [AgentWorkspace], profileID: String) {
        _ = saveReconciled(workspaces, profileID: profileID)
    }

    @discardableResult
    func saveReconciled(
        _ workspaces: [AgentWorkspace],
        profileID: String
    ) -> RecentWorkspaceReconciliation {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return .empty
        }
        var storage = storage()
        let reconciliation = boundedReconciliation(workspaces)
        storage.byProfileID[profileKey] = reconciliation.workspaces
        persist(storage)
        return reconciliation
    }

    func upsert(_ workspace: AgentWorkspace, endpoint: String, openedAt: Date = Date()) -> [AgentWorkspace] {
        upsertReconciled(
            workspace,
            endpoint: endpoint,
            openedAt: openedAt
        ).workspaces
    }

    func upsertReconciled(
        _ workspace: AgentWorkspace,
        endpoint: String,
        openedAt: Date = Date(),
        equivalentPaths: [String] = [],
        prefersIncomingIdentity: Bool = true
    ) -> RecentWorkspaceReconciliation {
        let loaded = loadReconciled(endpoint: endpoint)
        let updated = reconcile(
            [workspace.opened(at: openedAt)] + loaded.workspaces,
            preferredWorkspaceID: prefersIncomingIdentity ? workspace.id : nil,
            equivalentPaths: equivalentPaths
        )
        let next = boundedReconciliation(updated.workspaces)
        let combined = RecentWorkspaceReconciliation(
            workspaces: next.workspaces,
            replacedWorkspaceIDs: Self.combinedReplacements(
                loaded.replacedWorkspaceIDs,
                updated.replacedWorkspaceIDs,
                next.replacedWorkspaceIDs
            )
        )
        var storage = storage()
        storage.byEndpoint[normalizedEndpoint(endpoint)] = combined.workspaces
        persist(storage)
        return combined
    }

    func upsert(
        _ workspace: AgentWorkspace,
        profileID: String,
        openedAt: Date = Date()
    ) -> [AgentWorkspace] {
        upsertReconciled(
            workspace,
            profileID: profileID,
            openedAt: openedAt
        ).workspaces
    }

    func upsertReconciled(
        _ workspace: AgentWorkspace,
        profileID: String,
        openedAt: Date = Date(),
        equivalentPaths: [String] = [],
        prefersIncomingIdentity: Bool = true
    ) -> RecentWorkspaceReconciliation {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return .empty
        }
        let loaded = loadReconciled(profileID: profileID)
        let updated = reconcile(
            [workspace.opened(at: openedAt)] + loaded.workspaces,
            preferredWorkspaceID: prefersIncomingIdentity ? workspace.id : nil,
            equivalentPaths: equivalentPaths
        )
        let next = boundedReconciliation(updated.workspaces)
        let combined = RecentWorkspaceReconciliation(
            workspaces: next.workspaces,
            replacedWorkspaceIDs: Self.combinedReplacements(
                loaded.replacedWorkspaceIDs,
                updated.replacedWorkspaceIDs,
                next.replacedWorkspaceIDs
            )
        )
        var storage = storage()
        storage.byProfileID[profileKey] = combined.workspaces
        persist(storage)
        return combined
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

    private func boundedReconciliation(
        _ workspaces: [AgentWorkspace]
    ) -> RecentWorkspaceReconciliation {
        let reconciliation = reconcile(workspaces)
        return RecentWorkspaceReconciliation(
            workspaces: Array(reconciliation.workspaces.prefix(limit)),
            replacedWorkspaceIDs: reconciliation.replacedWorkspaceIDs
        )
    }

    private func reconcile(
        _ workspaces: [AgentWorkspace],
        preferredWorkspaceID: String? = nil,
        equivalentPaths: [String] = []
    ) -> RecentWorkspaceReconciliation {
        var remaining = workspaces
            .map(Self.normalizedWorkspace)
            .filter { !$0.id.isEmpty && !$0.path.isEmpty }
            .sorted {
                Self.workspacePrecedes(
                    $0,
                    $1,
                    preferredWorkspaceID: preferredWorkspaceID
                )
            }
        var merged: [AgentWorkspace] = []
        var replacements: [String: String] = [:]
        let preferredAliases = Set(equivalentPaths.map(WorkspacePathIdentity.normalizedPath))
            .filter { !$0.isEmpty }

        while !remaining.isEmpty {
            let winner = remaining.removeFirst()
            var group = [winner]
            var claimedIDs = Set([winner.id])
            var claimedPaths = Set([WorkspacePathIdentity.normalizedPath(winner.path)])
            if winner.id == preferredWorkspaceID {
                claimedPaths.formUnion(preferredAliases)
            }

            var foundMatch = true
            while foundMatch {
                foundMatch = false
                var unmatched: [AgentWorkspace] = []
                for candidate in remaining {
                    let candidatePath = WorkspacePathIdentity.normalizedPath(candidate.path)
                    if claimedIDs.contains(candidate.id) || claimedPaths.contains(candidatePath) {
                        group.append(candidate)
                        claimedIDs.insert(candidate.id)
                        claimedPaths.insert(candidatePath)
                        foundMatch = true
                    } else {
                        unmatched.append(candidate)
                    }
                }
                remaining = unmatched
            }

            var combined = winner
            for duplicate in group.dropFirst() {
                combined = Self.mergedWorkspace(preferred: combined, fallback: duplicate)
                if duplicate.id != combined.id {
                    replacements[duplicate.id] = combined.id
                }
            }
            merged.append(combined)
        }

        return RecentWorkspaceReconciliation(
            workspaces: merged.sorted(by: Self.workspaceSort),
            replacedWorkspaceIDs: Self.flattenedReplacements(replacements)
        )
    }

    private static func normalizedWorkspace(_ workspace: AgentWorkspace) -> AgentWorkspace {
        AgentWorkspace(
            id: workspace.id.trimmingCharacters(in: .whitespacesAndNewlines),
            name: workspace.name,
            path: WorkspacePathIdentity.normalizedPath(workspace.path),
            rootProjectID: normalizedOptional(workspace.rootProjectID),
            rootProjectName: normalizedOptional(workspace.rootProjectName),
            rootProjectPath: workspace.rootProjectPath.map(WorkspacePathIdentity.normalizedPath),
            lastOpenedAt: workspace.lastOpenedAt
        )
    }

    private static func mergedWorkspace(
        preferred: AgentWorkspace,
        fallback: AgentWorkspace
    ) -> AgentWorkspace {
        AgentWorkspace(
            id: preferred.id,
            name: preferred.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? fallback.name
                : preferred.name,
            path: preferred.path,
            rootProjectID: preferred.rootProjectID ?? fallback.rootProjectID,
            rootProjectName: preferred.rootProjectName ?? fallback.rootProjectName,
            rootProjectPath: preferred.rootProjectPath ?? fallback.rootProjectPath,
            lastOpenedAt: maxDate(preferred.lastOpenedAt, fallback.lastOpenedAt)
        )
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)):
            return max(lhs, rhs)
        case (.some(let lhs), .none):
            return lhs
        case (.none, .some(let rhs)):
            return rhs
        case (.none, .none):
            return nil
        }
    }

    private static func workspacePrecedes(
        _ lhs: AgentWorkspace,
        _ rhs: AgentWorkspace,
        preferredWorkspaceID: String?
    ) -> Bool {
        let lhsIsPreferred = lhs.id == preferredWorkspaceID
        let rhsIsPreferred = rhs.id == preferredWorkspaceID
        if lhsIsPreferred != rhsIsPreferred {
            return lhsIsPreferred
        }

        // 被动读取旧数据时稳定 ws_<path hash> 优先于兼容 project ID，避免下次
        // agentd resolve 又把 identity 切回去；显式打开时 preferredWorkspaceID 优先级更高。
        let lhsIsCanonical = lhs.id.hasPrefix("ws_")
        let rhsIsCanonical = rhs.id.hasPrefix("ws_")
        if lhsIsCanonical != rhsIsCanonical {
            return lhsIsCanonical
        }
        if lhs.lastOpenedAt != rhs.lastOpenedAt {
            return (lhs.lastOpenedAt ?? .distantPast) > (rhs.lastOpenedAt ?? .distantPast)
        }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }

    private static func combinedReplacements(
        _ replacements: [String: String]...
    ) -> [String: String] {
        var combined: [String: String] = [:]
        for replacement in replacements {
            for (oldID, newID) in replacement {
                combined[oldID] = newID
                let chainedOldIDs = combined.compactMap { existingOldID, existingNewID in
                    existingNewID == oldID ? existingOldID : nil
                }
                for existingOldID in chainedOldIDs {
                    combined[existingOldID] = newID
                }
            }
        }
        return flattenedReplacements(combined)
    }

    private static func flattenedReplacements(
        _ replacements: [String: String]
    ) -> [String: String] {
        var flattened: [String: String] = [:]
        for oldID in replacements.keys {
            var targetID = replacements[oldID] ?? oldID
            var visited = Set([oldID])
            while let nextID = replacements[targetID], !visited.contains(targetID) {
                visited.insert(targetID)
                targetID = nextID
            }
            if oldID != targetID {
                flattened[oldID] = targetID
            }
        }
        return flattened
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
