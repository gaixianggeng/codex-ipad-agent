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
