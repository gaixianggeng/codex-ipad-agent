import Combine
import CryptoKit
import Foundation

enum WorkspaceIconStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case journey
    case emoji

    var id: String { rawValue }

    var title: String {
        switch self {
        case .journey:
            return L10n.text("ui.journey_to_the_west")
        case .emoji:
            return L10n.text("ui.emoji")
        }
    }
}

struct WorkspaceCharacterIcon: Identifiable, Equatable, Sendable {
    let id: String
    let assetName: String
    let nameKey: String

    /// 角色 ID 和资源名需要保持稳定，展示名则跟随 App 当前语言动态解析。
    var name: String {
        L10n.text(nameKey)
    }
}

private struct WorkspaceAppearancePreferences: Codable {
    var style: WorkspaceIconStyle?
    var characterIDsByProject: [String: String] = [:]
    var emojiByProject: [String: String] = [:]

    var isEmpty: Bool {
        style == nil && characterIDsByProject.isEmpty && emojiByProject.isEmpty
    }

    mutating func mergeMissingValues(from legacy: Self) {
        if style == nil {
            style = legacy.style
        }
        for (projectID, characterID) in legacy.characterIDsByProject
            where characterIDsByProject[projectID] == nil {
            characterIDsByProject[projectID] = characterID
        }
        for (projectID, emoji) in legacy.emojiByProject where emojiByProject[projectID] == nil {
            emojiByProject[projectID] = emoji
        }
    }
}

/// 工作区图标是当前设备的展示偏好，不属于远端项目配置，也不参与会话状态同步。
@MainActor
final class WorkspaceAppearanceStore: ObservableObject {
    static let builtInEmoji = ["🐱", "🤖", "🦧", "🌻", "🍔", "⚾️", "🌍", "🌓", "🌈", "🚕", "🌋", "🍍", "📮"]

    static let builtInCharacters = [
        WorkspaceCharacterIcon(id: "sun-wukong", assetName: "WorkspaceCharacterSunWukong", nameKey: "ui.workspace_character_sun_wukong"),
        WorkspaceCharacterIcon(id: "tang-sanzang", assetName: "WorkspaceCharacterTangSanzang", nameKey: "ui.workspace_character_tang_sanzang"),
        WorkspaceCharacterIcon(id: "zhu-bajie", assetName: "WorkspaceCharacterZhuBajie", nameKey: "ui.workspace_character_zhu_bajie"),
        WorkspaceCharacterIcon(id: "sha-wujing", assetName: "WorkspaceCharacterShaWujing", nameKey: "ui.workspace_character_sha_wujing"),
        WorkspaceCharacterIcon(id: "white-dragon-horse", assetName: "WorkspaceCharacterWhiteDragonHorse", nameKey: "ui.workspace_character_white_dragon_horse"),
        WorkspaceCharacterIcon(id: "guanyin", assetName: "WorkspaceCharacterGuanyin", nameKey: "ui.workspace_character_guanyin"),
        WorkspaceCharacterIcon(id: "tathagata", assetName: "WorkspaceCharacterTathagata", nameKey: "ui.workspace_character_tathagata"),
        WorkspaceCharacterIcon(id: "jade-emperor", assetName: "WorkspaceCharacterJadeEmperor", nameKey: "ui.workspace_character_jade_emperor"),
        WorkspaceCharacterIcon(id: "taishang-laojun", assetName: "WorkspaceCharacterTaishangLaojun", nameKey: "ui.workspace_character_taishang_laojun"),
        WorkspaceCharacterIcon(id: "nezha", assetName: "WorkspaceCharacterNezha", nameKey: "ui.workspace_character_nezha"),
        WorkspaceCharacterIcon(id: "erlang-shen", assetName: "WorkspaceCharacterErlangShen", nameKey: "ui.workspace_character_erlang_shen"),
        WorkspaceCharacterIcon(id: "bull-demon-king", assetName: "WorkspaceCharacterBullDemonKing", nameKey: "ui.workspace_character_bull_demon_king"),
        WorkspaceCharacterIcon(id: "princess-iron-fan", assetName: "WorkspaceCharacterPrincessIronFan", nameKey: "ui.workspace_character_princess_iron_fan"),
        WorkspaceCharacterIcon(id: "red-boy", assetName: "WorkspaceCharacterRedBoy", nameKey: "ui.workspace_character_red_boy"),
        WorkspaceCharacterIcon(id: "white-bone-demon", assetName: "WorkspaceCharacterWhiteBoneDemon", nameKey: "ui.workspace_character_white_bone_demon"),
        WorkspaceCharacterIcon(id: "spider-demon", assetName: "WorkspaceCharacterSpiderDemon", nameKey: "ui.workspace_character_spider_demon"),
        WorkspaceCharacterIcon(id: "yellow-robed-demon", assetName: "WorkspaceCharacterYellowRobedDemon", nameKey: "ui.workspace_character_yellow_robed_demon"),
        WorkspaceCharacterIcon(id: "golden-horn-king", assetName: "WorkspaceCharacterGoldenHornKing", nameKey: "ui.workspace_character_golden_horn_king"),
        WorkspaceCharacterIcon(id: "silver-horn-king", assetName: "WorkspaceCharacterSilverHornKing", nameKey: "ui.workspace_character_silver_horn_king"),
        WorkspaceCharacterIcon(id: "queen-womens-kingdom", assetName: "WorkspaceCharacterQueenWomensKingdom", nameKey: "ui.workspace_character_queen_womens_kingdom")
    ]

    private typealias Storage = ProfileScopedStorage<WorkspaceAppearancePreferences>
    private typealias LegacyStorage = ProfileScopedStorage<[String: String]>

    @Published private var storage: Storage

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "agentd.workspaceAppearancePreferences.v2",
        legacyKey: String = "agentd.workspaceAppearancePreferences.v1"
    ) {
        self.defaults = defaults
        self.key = key

        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
            storage = decoded
        } else if let legacyData = defaults.data(forKey: legacyKey),
                  let legacy = try? JSONDecoder().decode(LegacyStorage.self, from: legacyData) {
            // v1 的单一字典可能同时残留 Emoji 和新版角色 ID。首次读取时分类复制到 v2，
            // 旧键保持只读，确保升级失败也不会破坏用户原来的选择。
            let migrated = Self.migratedStorage(from: legacy)
            storage = migrated
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: key)
            }
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
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        let endpointKey = AgentAPIClient.normalizedEndpoint(endpoint)
        guard !storage.migratedLegacyEndpoints.contains(endpointKey),
              ProfileScopedPersistence.isUniqueEndpointMatch(
                  profileID: profileKey,
                  normalizedEndpoint: endpointKey,
                  profiles: profiles
              ),
              let legacyPreferences = storage.byEndpoint[endpointKey]
        else {
            return
        }

        var preferences = storage.byProfileID[profileKey] ?? WorkspaceAppearancePreferences()
        preferences.mergeMissingValues(from: legacyPreferences)
        storage.byProfileID[profileKey] = preferences
        storage.migratedLegacyEndpoints.insert(endpointKey)
        persist()
    }

    func style(profileID: String) -> WorkspaceIconStyle {
        preferences(profileID: profileID)?.style ?? .journey
    }

    func setStyle(_ style: WorkspaceIconStyle, profileID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var preferences = storage.byProfileID[profileKey] ?? WorkspaceAppearancePreferences()
        guard preferences.style != style else { return }
        preferences.style = style
        storage.byProfileID[profileKey] = preferences
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

            let character = availableCharacter ?? Self.builtInCharacters[startIndex]
            assignments[projectID] = character
            usedCharacterIDs.insert(character.id)
        }

        return assignments
    }

    func customCharacterID(profileID: String, projectID: String) -> String? {
        guard let storedValue = preferences(profileID: profileID)?.characterIDsByProject[projectID],
              Self.character(id: storedValue) != nil else {
            return nil
        }
        return storedValue
    }

    func defaultCharacterID(profileID: String, projectID: String) -> String {
        Self.builtInCharacters[defaultCharacterIndex(profileID: profileID, projectID: projectID)].id
    }

    func setCustomCharacterID(_ characterID: String?, profileID: String, projectID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var preferences = storage.byProfileID[profileKey] ?? WorkspaceAppearancePreferences()
        if let characterID {
            guard Self.character(id: characterID) != nil else { return }
            preferences.characterIDsByProject[projectID] = characterID
        } else {
            preferences.characterIDsByProject.removeValue(forKey: projectID)
        }
        save(preferences, profileKey: profileKey)
    }

    func emoji(profileID: String, projectID: String) -> String {
        customEmoji(profileID: profileID, projectID: projectID)
            ?? defaultEmoji(profileID: profileID, projectID: projectID)
    }

    func emojiAssignments(profileID: String, projectIDs: [String]) -> [String: String] {
        let uniqueProjectIDs = Array(Set(projectIDs)).sorted()
        guard !uniqueProjectIDs.isEmpty, !Self.builtInEmoji.isEmpty else {
            return [:]
        }

        var assignments: [String: String] = [:]
        var usedEmoji = Set<String>()

        // 保留不冲突的历史手动选择；旧数据里已经重复的项目回到稳定自动分配。
        for projectID in uniqueProjectIDs {
            guard let custom = customEmoji(profileID: profileID, projectID: projectID),
                  !usedEmoji.contains(custom) else {
                continue
            }
            assignments[projectID] = custom
            usedEmoji.insert(custom)
        }

        for projectID in uniqueProjectIDs where assignments[projectID] == nil {
            let startIndex = defaultEmojiIndex(profileID: profileID, projectID: projectID)
            let availableEmoji = (0..<Self.builtInEmoji.count)
                .lazy
                .map { Self.builtInEmoji[(startIndex + $0) % Self.builtInEmoji.count] }
                .first { !usedEmoji.contains($0) }
            let emoji = availableEmoji ?? Self.builtInEmoji[startIndex]
            assignments[projectID] = emoji
            usedEmoji.insert(emoji)
        }

        return assignments
    }

    func customEmoji(profileID: String, projectID: String) -> String? {
        guard let storedValue = preferences(profileID: profileID)?.emojiByProject[projectID] else {
            return nil
        }
        return Self.normalizedEmoji(storedValue)
    }

    func defaultEmoji(profileID: String, projectID: String) -> String {
        Self.builtInEmoji[defaultEmojiIndex(profileID: profileID, projectID: projectID)]
    }

    func setCustomEmoji(_ emoji: String?, profileID: String, projectID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var preferences = storage.byProfileID[profileKey] ?? WorkspaceAppearancePreferences()
        if let emoji {
            guard let normalized = Self.normalizedEmoji(emoji) else { return }
            preferences.emojiByProject[projectID] = normalized
        } else {
            preferences.emojiByProject.removeValue(forKey: projectID)
        }
        save(preferences, profileKey: profileKey)
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

    static func normalizedEmoji(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 1 else { return nil }

        let scalars = Array(value.unicodeScalars)
        let hasPresentationEmoji = scalars.contains { $0.properties.isEmojiPresentation }
        let hasEmojiWithPresentationSelector = scalars.contains { $0.properties.isEmoji }
            && scalars.contains { $0.value == 0xFE0F }
        guard hasPresentationEmoji || hasEmojiWithPresentationSelector else {
            return nil
        }
        return value
    }

    static func tintIndex(for emoji: String, count: Int) -> Int {
        stableIndex(for: emoji, count: count)
    }

    private func preferences(profileID: String) -> WorkspaceAppearancePreferences? {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return nil
        }
        return storage.byProfileID[profileKey]
    }

    private func defaultCharacterIndex(profileID: String, projectID: String) -> Int {
        Self.stableIndex(
            for: stableIdentity(profileID: profileID, projectID: projectID),
            count: Self.builtInCharacters.count
        )
    }

    private func defaultEmojiIndex(profileID: String, projectID: String) -> Int {
        Self.stableIndex(
            for: stableIdentity(profileID: profileID, projectID: projectID),
            count: Self.builtInEmoji.count
        )
    }

    private func stableIdentity(profileID: String, projectID: String) -> String {
        let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) ?? "legacy"
        return "\(profileKey)\n\(projectID)"
    }

    private func save(_ preferences: WorkspaceAppearancePreferences, profileKey: String) {
        if preferences.isEmpty {
            storage.byProfileID.removeValue(forKey: profileKey)
        } else {
            storage.byProfileID[profileKey] = preferences
        }
        persist()
    }

    private static func migratedStorage(from legacy: LegacyStorage) -> Storage {
        var migrated = Storage()
        migrated.byEndpoint = legacy.byEndpoint.mapValues(migratedPreferences)
        migrated.byProfileID = legacy.byProfileID.mapValues(migratedPreferences)
        migrated.migratedLegacyEndpoints = legacy.migratedLegacyEndpoints
        return migrated
    }

    private static func migratedPreferences(
        from legacyValues: [String: String]
    ) -> WorkspaceAppearancePreferences {
        var preferences = WorkspaceAppearancePreferences()
        for (projectID, value) in legacyValues {
            if character(id: value) != nil {
                preferences.characterIDsByProject[projectID] = value
            } else if let emoji = normalizedEmoji(value) {
                preferences.emojiByProject[projectID] = emoji
            }
        }

        // 兼容老用户优先：只要存在历史 Emoji 就继续展示 Emoji；完全没有历史选择时
        // style 保持 nil，由读取逻辑使用《西游记》作为新用户默认值。
        if !preferences.emojiByProject.isEmpty {
            preferences.style = .emoji
        } else if !preferences.characterIDsByProject.isEmpty {
            preferences.style = .journey
        }
        return preferences
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
