import Combine
import CryptoKit
import Foundation

struct WorkspaceCharacterIcon: Identifiable, Equatable, Sendable {
    let id: String
    let assetName: String
    let name: String
}

/// 工作区角色图标是当前设备的展示偏好，不属于远端项目配置，也不参与会话状态同步。
@MainActor
final class WorkspaceAppearanceStore: ObservableObject {
    static let builtInCharacters = [
        WorkspaceCharacterIcon(id: "sun-wukong", assetName: "WorkspaceCharacterSunWukong", name: "孙悟空"),
        WorkspaceCharacterIcon(id: "tang-sanzang", assetName: "WorkspaceCharacterTangSanzang", name: "唐僧"),
        WorkspaceCharacterIcon(id: "zhu-bajie", assetName: "WorkspaceCharacterZhuBajie", name: "猪八戒"),
        WorkspaceCharacterIcon(id: "sha-wujing", assetName: "WorkspaceCharacterShaWujing", name: "沙悟净"),
        WorkspaceCharacterIcon(id: "white-dragon-horse", assetName: "WorkspaceCharacterWhiteDragonHorse", name: "白龙马"),
        WorkspaceCharacterIcon(id: "guanyin", assetName: "WorkspaceCharacterGuanyin", name: "观音菩萨"),
        WorkspaceCharacterIcon(id: "tathagata", assetName: "WorkspaceCharacterTathagata", name: "如来佛祖"),
        WorkspaceCharacterIcon(id: "jade-emperor", assetName: "WorkspaceCharacterJadeEmperor", name: "玉皇大帝"),
        WorkspaceCharacterIcon(id: "taishang-laojun", assetName: "WorkspaceCharacterTaishangLaojun", name: "太上老君"),
        WorkspaceCharacterIcon(id: "nezha", assetName: "WorkspaceCharacterNezha", name: "哪吒"),
        WorkspaceCharacterIcon(id: "erlang-shen", assetName: "WorkspaceCharacterErlangShen", name: "二郎神"),
        WorkspaceCharacterIcon(id: "bull-demon-king", assetName: "WorkspaceCharacterBullDemonKing", name: "牛魔王"),
        WorkspaceCharacterIcon(id: "princess-iron-fan", assetName: "WorkspaceCharacterPrincessIronFan", name: "铁扇公主"),
        WorkspaceCharacterIcon(id: "red-boy", assetName: "WorkspaceCharacterRedBoy", name: "红孩儿"),
        WorkspaceCharacterIcon(id: "white-bone-demon", assetName: "WorkspaceCharacterWhiteBoneDemon", name: "白骨精"),
        WorkspaceCharacterIcon(id: "spider-demon", assetName: "WorkspaceCharacterSpiderDemon", name: "蜘蛛精"),
        WorkspaceCharacterIcon(id: "yellow-robed-demon", assetName: "WorkspaceCharacterYellowRobedDemon", name: "黄袍怪"),
        WorkspaceCharacterIcon(id: "golden-horn-king", assetName: "WorkspaceCharacterGoldenHornKing", name: "金角大王"),
        WorkspaceCharacterIcon(id: "silver-horn-king", assetName: "WorkspaceCharacterSilverHornKing", name: "银角大王"),
        WorkspaceCharacterIcon(id: "queen-womens-kingdom", assetName: "WorkspaceCharacterQueenWomensKingdom", name: "女儿国国王")
    ]

    private typealias Storage = ProfileScopedStorage<[String: String]>

    @Published private var storage: Storage

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "agentd.workspaceAppearancePreferences.v1"
    ) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
            storage = decoded
        } else {
            storage = Storage()
        }
    }

    /// endpoint 旧值只在唯一匹配的 Profile 上迁移一次；地址只是路由，不能继续作为偏好主键。
    func migrateLegacyValueIfNeeded(
        profileID: String,
        endpoint: String,
        profiles: [ConnectionProfile]
    ) {
        guard storage.migrateLegacyValueIfUnique(
            profileID: profileID,
            endpoint: endpoint,
            profiles: profiles
        ) else {
            return
        }
        persist()
    }

    func character(profileID: String, projectID: String) -> WorkspaceCharacterIcon {
        let characterID = customCharacterID(profileID: profileID, projectID: projectID)
            ?? defaultCharacterID(profileID: profileID, projectID: projectID)
        // defaultCharacterID 必定来自内置池；保留兜底，避免未来资源清单调整时出现空图。
        return Self.character(id: characterID) ?? Self.builtInCharacters[0]
    }

    /// 为同一 Profile 下当前可见的整组项目统一分配角色。
    ///
    /// 单独对哈希取模无法避免碰撞；这里先保留用户手动选择，再从每个项目的稳定哈希起点
    /// 向后寻找空位。角色数足够时自动头像不会重复，项目超过角色池容量后才允许复用。
    func characterAssignments(
        profileID: String,
        projectIDs: [String]
    ) -> [String: WorkspaceCharacterIcon] {
        let uniqueProjectIDs = Array(Set(projectIDs)).sorted()
        guard !uniqueProjectIDs.isEmpty, !Self.builtInCharacters.isEmpty else {
            return [:]
        }

        var assignments: [String: WorkspaceCharacterIcon] = [:]
        var usedCharacterIDs = Set<String>()

        // 手动选择优先占位；历史数据若已经重复，只保留首个占位，其余项目回到空位分配。
        for projectID in uniqueProjectIDs {
            guard let customID = customCharacterID(profileID: profileID, projectID: projectID),
                  let character = Self.character(id: customID),
                  !usedCharacterIDs.contains(character.id) else {
                continue
            }
            assignments[projectID] = character
            usedCharacterIDs.insert(character.id)
        }

        for projectID in uniqueProjectIDs where assignments[projectID] == nil {
            let startIndex = defaultCharacterIndex(profileID: profileID, projectID: projectID)
            let availableCharacter = (0..<Self.builtInCharacters.count)
                .lazy
                .map { Self.builtInCharacters[(startIndex + $0) % Self.builtInCharacters.count] }
                .first { !usedCharacterIDs.contains($0.id) }

            // 超过角色池容量时不存在空位；退回项目自己的稳定哈希结果，让复用仍然可预测。
            let character = availableCharacter ?? Self.builtInCharacters[startIndex]
            assignments[projectID] = character
            usedCharacterIDs.insert(character.id)
        }

        return assignments
    }

    func customCharacterID(profileID: String, projectID: String) -> String? {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return nil
        }
        guard let storedValue = storage.byProfileID[profileKey]?[projectID],
              Self.character(id: storedValue) != nil else {
            // v1 曾保存 Emoji；无法识别的旧值直接回退到新的稳定默认角色。
            return nil
        }
        return storedValue
    }

    func defaultCharacterID(profileID: String, projectID: String) -> String {
        Self.builtInCharacters[defaultCharacterIndex(profileID: profileID, projectID: projectID)].id
    }

    private func defaultCharacterIndex(profileID: String, projectID: String) -> Int {
        let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) ?? "legacy"
        let identity = "\(profileKey)\n\(projectID)"
        return Self.stableIndex(for: identity, count: Self.builtInCharacters.count)
    }

    func setCustomCharacterID(_ characterID: String?, profileID: String, projectID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var projectValues = storage.byProfileID[profileKey] ?? [:]
        if let characterID {
            guard Self.character(id: characterID) != nil else { return }
            projectValues[projectID] = characterID
        } else {
            projectValues.removeValue(forKey: projectID)
        }
        if projectValues.isEmpty {
            storage.byProfileID.removeValue(forKey: profileKey)
        } else {
            storage.byProfileID[profileKey] = projectValues
        }
        persist()
    }

    func remove(profileID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID),
              storage.byProfileID.removeValue(forKey: profileKey) != nil else {
            return
        }
        persist()
    }

    static func character(id: String) -> WorkspaceCharacterIcon? {
        builtInCharacters.first { $0.id == id }
    }

    private static func stableIndex(for value: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let digest = SHA256.hash(data: Data(value.utf8))
        var prefix: UInt64 = 0
        for byte in digest.prefix(8) {
            prefix = (prefix << 8) | UInt64(byte)
        }
        return Int(prefix % UInt64(count))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: key)
    }
}
