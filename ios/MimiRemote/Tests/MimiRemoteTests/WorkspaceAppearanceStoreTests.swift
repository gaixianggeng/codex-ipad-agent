import Foundation
import XCTest
@testable import MimiRemote

@MainActor
final class WorkspaceAppearanceStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "WorkspaceAppearanceStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testBuiltInCharacterPoolKeepsProductOrder() {
        XCTAssertEqual(
            WorkspaceAppearanceStore.builtInCharacters.map(\.id),
            [
                "sun-wukong", "tang-sanzang", "zhu-bajie", "sha-wujing", "white-dragon-horse",
                "guanyin", "tathagata", "jade-emperor", "taishang-laojun", "nezha",
                "erlang-shen", "bull-demon-king", "princess-iron-fan", "red-boy", "white-bone-demon",
                "spider-demon", "yellow-robed-demon", "golden-horn-king", "silver-horn-king",
                "queen-womens-kingdom"
            ]
        )
    }

    func testBuiltInCharacterNamesHaveEnglishAndChineseLocalizations() {
        let allCharacters = WorkspaceIconStyle.allCases
            .filter(\.usesCharacters)
            .flatMap { WorkspaceAppearanceStore.characters(for: $0) }

        for character in allCharacters {
            let englishName = L10n.text(character.nameKey, language: .english)
            let chineseName = L10n.text(character.nameKey, language: .simplifiedChinese)

            XCTAssertNotEqual(englishName, character.nameKey, "缺少英文角色名：\(character.id)")
            XCTAssertNotEqual(chineseName, character.nameKey, "缺少中文角色名：\(character.id)")
            XCTAssertNotEqual(englishName, chineseName, "中英文角色名不应共用未翻译文案：\(character.id)")
        }
    }

    func testEveryNewCharacterStyleContainsTenUniqueCharacters() {
        let newStyles: [WorkspaceIconStyle] = [
            .threeKingdoms,
            .waterMargin,
            .redChamber,
            .greekMythology,
            .sherlockHolmes,
            .aliceWonderland
        ]
        let newCharacters = newStyles.flatMap {
            WorkspaceAppearanceStore.characters(for: $0)
        }

        for style in newStyles {
            XCTAssertEqual(
                WorkspaceAppearanceStore.characters(for: style).count,
                10,
                "\(style.rawValue) 应提供 10 个角色"
            )
        }
        XCTAssertEqual(Set(newCharacters.map(\.id)).count, 60)
        XCTAssertEqual(Set(newCharacters.map(\.assetName)).count, 60)
        XCTAssertTrue(WorkspaceAppearanceStore.characters(for: .emoji).isEmpty)
    }

    func testEveryNewCharacterStyleAssignsTenProjectsUniquelyAndStably() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let projectIDs = (0..<10).map { "project-\($0)" }
        let newStyles: [WorkspaceIconStyle] = [
            .threeKingdoms,
            .waterMargin,
            .redChamber,
            .greekMythology,
            .sherlockHolmes,
            .aliceWonderland
        ]

        for style in newStyles {
            let assignments = store.characterAssignments(
                style: style,
                profileID: "mac-a",
                projectIDs: projectIDs
            )

            XCTAssertEqual(assignments.count, 10)
            XCTAssertEqual(Set(assignments.values.map(\.id)).count, 10)
            XCTAssertEqual(
                store.characterAssignments(
                    style: style,
                    profileID: "mac-a",
                    projectIDs: Array(projectIDs.reversed())
                ),
                assignments,
                "\(style.rawValue) 不应因项目输入顺序变化重新洗牌"
            )
        }
    }

    func testAllWorkspaceIconStyleNamesHaveEnglishAndChineseLocalizations() {
        for style in WorkspaceIconStyle.allCases {
            let englishName = L10n.text(style.titleKey, language: .english)
            let chineseName = L10n.text(style.titleKey, language: .simplifiedChinese)

            XCTAssertNotEqual(englishName, style.titleKey)
            XCTAssertNotEqual(chineseName, style.titleKey)
        }
    }

    func testBuiltInEmojiPoolKeepsPreviousProductChoices() {
        XCTAssertEqual(
            WorkspaceAppearanceStore.builtInEmoji,
            ["🐱", "🤖", "🦧", "🌻", "🍔", "⚾️", "🌍", "🌓", "🌈", "🚕", "🌋", "🍍", "📮"]
        )
    }

    func testNewProfileDefaultsToJourneyStyle() {
        let store = WorkspaceAppearanceStore(defaults: defaults)

        XCTAssertEqual(store.style(profileID: "mac-a"), .journey)
    }

    func testLegacyEmojiSelectionRestoresEmojiStyleAndChoice() throws {
        let legacy = [
            "byProfileID": [
                "mac-a": [
                    "project-1": "🌻",
                    "project-2": "🤖"
                ]
            ]
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: legacy),
            forKey: "agentd.workspaceAppearancePreferences.v1"
        )

        let store = WorkspaceAppearanceStore(defaults: defaults)

        XCTAssertEqual(store.style(profileID: "mac-a"), .emoji)
        XCTAssertEqual(store.customEmoji(profileID: "mac-a", projectID: "project-1"), "🌻")
        XCTAssertEqual(store.customEmoji(profileID: "mac-a", projectID: "project-2"), "🤖")
    }

    func testLegacyEndpointEmojiMigrationRestoresStyleBeforeWorkspaceOpens() throws {
        let endpoint = "http://mac-a.local:8787"
        let legacy = [
            "byEndpoint": [
                endpoint: [
                    "project-1": "🦧"
                ]
            ]
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: legacy),
            forKey: "agentd.workspaceAppearancePreferences.v1"
        )
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "Mac A",
            endpoint: endpoint,
            lastSuccessfulAt: nil
        )
        let store = WorkspaceAppearanceStore(defaults: defaults)

        XCTAssertEqual(store.style(profileID: profile.id), .journey)

        store.migrateLegacyValueIfNeeded(
            profileID: profile.id,
            endpoint: profile.endpoint,
            profiles: [profile]
        )

        XCTAssertEqual(store.style(profileID: profile.id), .emoji)
        XCTAssertEqual(store.customEmoji(profileID: profile.id, projectID: "project-1"), "🦧")
    }

    func testStyleAndTwoKindsOfProjectChoicesPersistIndependently() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        store.setCustomEmoji("🌈", profileID: "mac-a", projectID: "project-1")
        store.setCustomCharacterID("red-boy", profileID: "mac-a", projectID: "project-1")
        store.setStyle(.emoji, profileID: "mac-a")

        let restored = WorkspaceAppearanceStore(defaults: defaults)
        XCTAssertEqual(restored.style(profileID: "mac-a"), .emoji)
        XCTAssertEqual(restored.customEmoji(profileID: "mac-a", projectID: "project-1"), "🌈")
        XCTAssertEqual(
            restored.customCharacterID(profileID: "mac-a", projectID: "project-1"),
            "red-boy"
        )

        restored.setStyle(.journey, profileID: "mac-a")
        let switchedBack = WorkspaceAppearanceStore(defaults: defaults)
        XCTAssertEqual(switchedBack.style(profileID: "mac-a"), .journey)
        XCTAssertEqual(switchedBack.customEmoji(profileID: "mac-a", projectID: "project-1"), "🌈")
        XCTAssertEqual(
            switchedBack.customCharacterID(profileID: "mac-a", projectID: "project-1"),
            "red-boy"
        )
    }

    func testCharacterChoicesPersistIndependentlyForEachStyle() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        store.setCustomCharacterID(
            "three-guan-yu",
            style: .threeKingdoms,
            profileID: "mac-a",
            projectID: "project-1"
        )
        store.setCustomCharacterID(
            "water-wu-song",
            style: .waterMargin,
            profileID: "mac-a",
            projectID: "project-1"
        )

        let restored = WorkspaceAppearanceStore(defaults: defaults)
        XCTAssertEqual(
            restored.customCharacterID(
                style: .threeKingdoms,
                profileID: "mac-a",
                projectID: "project-1"
            ),
            "three-guan-yu"
        )
        XCTAssertEqual(
            restored.customCharacterID(
                style: .waterMargin,
                profileID: "mac-a",
                projectID: "project-1"
            ),
            "water-wu-song"
        )
        XCTAssertNil(
            restored.customCharacterID(
                style: .redChamber,
                profileID: "mac-a",
                projectID: "project-1"
            )
        )
    }

    func testPreviouslyPersistedV2PreferencesDecodeWithoutNewStyleMap() throws {
        let previousV2: [String: Any] = [
            "byProfileID": [
                "mac-a": [
                    "style": "journey",
                    "characterIDsByProject": ["project-1": "red-boy"],
                    "emojiByProject": ["project-1": "🌈"]
                ]
            ]
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: previousV2),
            forKey: "agentd.workspaceAppearancePreferences.v2"
        )

        let restored = WorkspaceAppearanceStore(defaults: defaults)

        XCTAssertEqual(restored.style(profileID: "mac-a"), .journey)
        XCTAssertEqual(
            restored.customCharacterID(profileID: "mac-a", projectID: "project-1"),
            "red-boy"
        )
        XCTAssertEqual(restored.customEmoji(profileID: "mac-a", projectID: "project-1"), "🌈")
    }

    func testStylePreferenceStaysScopedToConnectionProfile() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        store.setStyle(.emoji, profileID: "mac-a")

        XCTAssertEqual(store.style(profileID: "mac-a"), .emoji)
        XCTAssertEqual(store.style(profileID: "mac-b"), .journey)
    }

    func testDefaultCharacterIsStableForProfileAndProject() {
        let first = WorkspaceAppearanceStore(defaults: defaults)
        let value = first.defaultCharacterID(profileID: "mac-a", projectID: "project-1")

        let restored = WorkspaceAppearanceStore(defaults: defaults)
        XCTAssertEqual(
            restored.defaultCharacterID(profileID: "mac-a", projectID: "project-1"),
            value
        )
        XCTAssertTrue(WorkspaceAppearanceStore.builtInCharacters.map(\.id).contains(value))
    }

    func testCharacterAssignmentsStayUniqueWhilePoolHasCapacity() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let projectIDs = (0..<WorkspaceAppearanceStore.builtInCharacters.count)
            .map { "project-\($0)" }

        let assignments = store.characterAssignments(
            profileID: "mac-a",
            projectIDs: projectIDs
        )

        XCTAssertEqual(assignments.count, projectIDs.count)
        XCTAssertEqual(
            Set(assignments.values.map(\.id)).count,
            WorkspaceAppearanceStore.builtInCharacters.count
        )
        XCTAssertEqual(
            store.characterAssignments(profileID: "mac-a", projectIDs: Array(projectIDs.reversed())),
            assignments,
            "项目输入顺序变化不应导致头像重新洗牌"
        )
    }

    func testCharacterAssignmentsReserveCustomChoiceBeforeAutomaticAllocation() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let projectIDs = (0..<10).map { "project-\($0)" }
        store.setCustomCharacterID(
            "sun-wukong",
            profileID: "mac-a",
            projectID: projectIDs[4]
        )

        let assignments = store.characterAssignments(
            profileID: "mac-a",
            projectIDs: projectIDs
        )

        XCTAssertEqual(assignments[projectIDs[4]]?.id, "sun-wukong")
        XCTAssertEqual(Set(assignments.values.map(\.id)).count, projectIDs.count)
    }

    func testCharacterAssignmentsRepairDuplicateHistoricalCustomChoices() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let projectIDs = ["project-a", "project-b", "project-c"]
        store.setCustomCharacterID("red-boy", profileID: "mac-a", projectID: projectIDs[0])
        store.setCustomCharacterID("red-boy", profileID: "mac-a", projectID: projectIDs[1])

        let assignments = store.characterAssignments(
            profileID: "mac-a",
            projectIDs: projectIDs
        )

        XCTAssertEqual(assignments[projectIDs[0]]?.id, "red-boy")
        XCTAssertNotEqual(assignments[projectIDs[1]]?.id, "red-boy")
        XCTAssertEqual(Set(assignments.values.map(\.id)).count, projectIDs.count)
    }

    func testCharacterAssignmentsRepeatOnlyAfterPoolIsExhausted() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let projectIDs = (0...WorkspaceAppearanceStore.builtInCharacters.count)
            .map { "project-\($0)" }

        let assignments = store.characterAssignments(
            profileID: "mac-a",
            projectIDs: projectIDs
        )

        XCTAssertEqual(assignments.count, projectIDs.count)
        XCTAssertEqual(
            Set(assignments.values.map(\.id)).count,
            WorkspaceAppearanceStore.builtInCharacters.count
        )
    }

    func testEmojiAssignmentsStayUniqueWhilePoolHasCapacity() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        let projectIDs = (0..<WorkspaceAppearanceStore.builtInEmoji.count)
            .map { "project-\($0)" }

        let assignments = store.emojiAssignments(
            profileID: "mac-a",
            projectIDs: projectIDs
        )

        XCTAssertEqual(assignments.count, projectIDs.count)
        XCTAssertEqual(
            Set(assignments.values).count,
            WorkspaceAppearanceStore.builtInEmoji.count
        )
        XCTAssertEqual(
            store.emojiAssignments(profileID: "mac-a", projectIDs: Array(projectIDs.reversed())),
            assignments,
            "项目输入顺序变化不应导致 Emoji 重新洗牌"
        )
    }

    func testCustomCharacterPersistsAndStaysScopedToProfileAndProject() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        store.setCustomCharacterID("red-boy", profileID: "mac-a", projectID: "project-1")

        let restored = WorkspaceAppearanceStore(defaults: defaults)
        XCTAssertEqual(
            restored.character(profileID: "mac-a", projectID: "project-1").id,
            "red-boy"
        )
        XCTAssertNotEqual(
            restored.customCharacterID(profileID: "mac-b", projectID: "project-1"),
            "red-boy"
        )
        XCTAssertNil(restored.customCharacterID(profileID: "mac-a", projectID: "project-2"))

        restored.setCustomCharacterID(nil, profileID: "mac-a", projectID: "project-1")
        XCTAssertNil(restored.customCharacterID(profileID: "mac-a", projectID: "project-1"))
    }

    func testLegacyEndpointCharacterMigratesOnlyForUniqueProfile() throws {
        let key = "agentd.workspaceAppearancePreferences.v1"
        let legacy = [
            "byEndpoint": [
                "http://mac-a.local:8787": [
                    "project-1": "nezha"
                ]
            ]
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: key)
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "Mac A",
            endpoint: "http://mac-a.local:8787",
            lastSuccessfulAt: nil
        )
        let store = WorkspaceAppearanceStore(defaults: defaults)

        store.migrateLegacyValueIfNeeded(
            profileID: profile.id,
            endpoint: profile.endpoint,
            profiles: [profile]
        )

        XCTAssertEqual(store.customCharacterID(profileID: profile.id, projectID: "project-1"), "nezha")
        XCTAssertNil(store.customCharacterID(profileID: "mac-b", projectID: "project-1"))
    }

    func testLegacyEndpointCharacterRetriesAfterAmbiguityResolves() throws {
        let key = "agentd.workspaceAppearancePreferences.v1"
        let endpoint = "http://shared-mac.local:8787"
        let legacy = [
            "byEndpoint": [
                endpoint: [
                    "project-1": "nezha"
                ]
            ]
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: key)
        let current = ConnectionProfile(
            id: "mac-a",
            displayName: "Mac A",
            endpoint: endpoint,
            lastSuccessfulAt: nil
        )
        let duplicate = ConnectionProfile(
            id: "mac-b",
            displayName: "Mac B",
            endpoint: endpoint + "/",
            lastSuccessfulAt: nil
        )
        let store = WorkspaceAppearanceStore(defaults: defaults)

        store.migrateLegacyValueIfNeeded(
            profileID: current.id,
            endpoint: current.endpoint,
            profiles: [current, duplicate]
        )
        XCTAssertNil(store.customCharacterID(profileID: current.id, projectID: "project-1"))

        store.migrateLegacyValueIfNeeded(
            profileID: current.id,
            endpoint: current.endpoint,
            profiles: [current]
        )
        XCTAssertEqual(store.customCharacterID(profileID: current.id, projectID: "project-1"), "nezha")
    }

    func testCustomCharacterRejectsUnknownAssetID() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        store.setCustomCharacterID("unknown-character", profileID: "mac-a", projectID: "project-1")
        XCTAssertNil(store.customCharacterID(profileID: "mac-a", projectID: "project-1"))
    }
}
