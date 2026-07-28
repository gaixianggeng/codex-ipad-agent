import XCTest
@testable import MimiRemote

@MainActor
final class HostWarmSnapshotTests: XCTestCase {
    func testCacheRetainsOnlyTwoMostRecentlyUsedProfiles() async {
        let cache = HostWarmSnapshotCache()
        await cache.store(snapshot(profileID: "mac-a"))
        await cache.store(snapshot(profileID: "mac-b"))
        XCTAssertNotNil(cache.snapshot(for: "mac-a"))

        await cache.store(snapshot(profileID: "mac-c"))

        XCTAssertNotNil(cache.snapshot(for: "mac-a"))
        XCTAssertNil(cache.snapshot(for: "mac-b"))
        XCTAssertNotNil(cache.snapshot(for: "mac-c"))
    }

    func testOversizedSnapshotIsNotRetained() async {
        let cache = HostWarmSnapshotCache()
        let oversizedProject = AgentProject(
            id: "large",
            name: "large",
            path: String(repeating: "x", count: HostWarmSnapshotCache.perHostByteLimit + 1)
        )
        let oversized = HostWarmSnapshot(
            profileID: "mac-large",
            projects: [oversizedProject],
            recentWorkspaces: [],
            sidebarProjects: [],
            sessions: [],
            selectedProjectID: nil,
            selectedSessionID: nil,
            selectedProjectCursor: nil,
            selectedProjectHasMore: false,
            blockingTaskCount: 0,
            capturedAt: Date()
        )

        await cache.store(oversized)

        XCTAssertNil(cache.snapshot(for: "mac-large"))
    }

    private func snapshot(profileID: String) -> HostWarmSnapshot {
        HostWarmSnapshot(
            profileID: profileID,
            projects: [],
            recentWorkspaces: [],
            sidebarProjects: [],
            sessions: [],
            selectedProjectID: nil,
            selectedSessionID: nil,
            selectedProjectCursor: nil,
            selectedProjectHasMore: false,
            blockingTaskCount: 0,
            capturedAt: Date()
        )
    }
}
