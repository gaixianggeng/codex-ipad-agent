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

    func testBuiltInEmojiPoolKeepsProductOrder() {
        XCTAssertEqual(
            WorkspaceAppearanceStore.builtInEmoji,
            ["🐱", "🤖", "🦧", "🌻", "🍔", "⚾️", "🌍", "🌓", "🌈", "🚕", "🌋", "🍍", "📮"]
        )
    }

    func testDefaultEmojiIsStableForProfileAndProject() {
        let first = WorkspaceAppearanceStore(defaults: defaults)
        let value = first.defaultEmoji(profileID: "mac-a", projectID: "project-1")

        let restored = WorkspaceAppearanceStore(defaults: defaults)
        XCTAssertEqual(
            restored.defaultEmoji(profileID: "mac-a", projectID: "project-1"),
            value
        )
        XCTAssertTrue(WorkspaceAppearanceStore.builtInEmoji.contains(value))
    }

    func testCustomEmojiPersistsAndStaysScopedToProfileAndProject() {
        let store = WorkspaceAppearanceStore(defaults: defaults)
        store.setCustomEmoji("🧑‍💻", profileID: "mac-a", projectID: "project-1")

        let restored = WorkspaceAppearanceStore(defaults: defaults)
        XCTAssertEqual(
            restored.emoji(profileID: "mac-a", projectID: "project-1"),
            "🧑‍💻"
        )
        XCTAssertNotEqual(
            restored.customEmoji(profileID: "mac-b", projectID: "project-1"),
            "🧑‍💻"
        )
        XCTAssertNil(restored.customEmoji(profileID: "mac-a", projectID: "project-2"))

        restored.setCustomEmoji(nil, profileID: "mac-a", projectID: "project-1")
        XCTAssertNil(restored.customEmoji(profileID: "mac-a", projectID: "project-1"))
    }

    func testLegacyEndpointEmojiMigratesOnlyForUniqueProfile() throws {
        let key = "agentd.workspaceAppearancePreferences.v1"
        let legacy = [
            "byEndpoint": [
                "http://mac-a.local:8787": [
                    "project-1": "🧑‍💻"
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

        XCTAssertEqual(store.customEmoji(profileID: profile.id, projectID: "project-1"), "🧑‍💻")
        XCTAssertNil(store.customEmoji(profileID: "mac-b", projectID: "project-1"))
    }

    func testLegacyEndpointEmojiRetriesAfterAmbiguityResolves() throws {
        let key = "agentd.workspaceAppearancePreferences.v1"
        let endpoint = "http://shared-mac.local:8787"
        let legacy = [
            "byEndpoint": [
                endpoint: [
                    "project-1": "🧑‍💻"
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
        XCTAssertNil(store.customEmoji(profileID: current.id, projectID: "project-1"))

        store.migrateLegacyValueIfNeeded(
            profileID: current.id,
            endpoint: current.endpoint,
            profiles: [current]
        )
        XCTAssertEqual(store.customEmoji(profileID: current.id, projectID: "project-1"), "🧑‍💻")
    }

    func testCustomEmojiAcceptsOneGraphemeAndRejectsPlainText() {
        XCTAssertEqual(WorkspaceAppearanceStore.normalizedEmoji("  🌈  "), "🌈")
        XCTAssertEqual(WorkspaceAppearanceStore.normalizedEmoji("⚾️"), "⚾️")
        XCTAssertNil(WorkspaceAppearanceStore.normalizedEmoji("A"))
        XCTAssertNil(WorkspaceAppearanceStore.normalizedEmoji("🐱🤖"))
        XCTAssertNil(WorkspaceAppearanceStore.normalizedEmoji("   "))
    }
}
