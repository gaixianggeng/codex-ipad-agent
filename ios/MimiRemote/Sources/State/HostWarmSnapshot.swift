import Foundation

struct HostWarmSnapshot: Codable, @unchecked Sendable {
    let profileID: String
    let projects: [AgentProject]
    let recentWorkspaces: [AgentWorkspace]
    let sidebarProjects: [AgentProject]
    let sessions: [AgentSession]
    let selectedProjectID: String?
    let selectedSessionID: String?
    let selectedProjectCursor: String?
    let selectedProjectHasMore: Bool
    let blockingTaskCount: Int
    let capturedAt: Date
}

@MainActor
final class HostWarmSnapshotCache {
    static let retainedHostLimit = 2
    static let perHostByteLimit = 1 * 1_024 * 1_024

    private struct Entry {
        let snapshot: HostWarmSnapshot
        let byteCount: Int
        let accessTick: UInt64
    }

    private var entriesByProfileID: [String: Entry] = [:]
    private var accessCounter: UInt64 = 0
    private var mutationCounter: UInt64 = 0
    private var pendingMutationByProfileID: [String: UInt64] = [:]

    func store(_ snapshot: HostWarmSnapshot) async {
        mutationCounter &+= 1
        let mutation = mutationCounter
        pendingMutationByProfileID[snapshot.profileID] = mutation
        // 编码只用于严格执行 1 MiB 预算，不能占用切换提交所在的 MainActor。
        let byteCount = await Task.detached(priority: .utility) {
            try? JSONEncoder().encode(snapshot).count
        }.value
        guard pendingMutationByProfileID[snapshot.profileID] == mutation else {
            return
        }
        pendingMutationByProfileID.removeValue(forKey: snapshot.profileID)
        guard let byteCount,
              byteCount <= Self.perHostByteLimit else {
            // 快照超出预算时宁可丢弃，也不能因为设备数量扩大常驻内存。
            entriesByProfileID.removeValue(forKey: snapshot.profileID)
            return
        }
        accessCounter &+= 1
        entriesByProfileID[snapshot.profileID] = Entry(
            snapshot: snapshot,
            byteCount: byteCount,
            accessTick: accessCounter
        )
        trimIfNeeded()
    }

    func snapshot(for profileID: String) -> HostWarmSnapshot? {
        guard let entry = entriesByProfileID[profileID] else {
            return nil
        }
        accessCounter &+= 1
        entriesByProfileID[profileID] = Entry(
            snapshot: entry.snapshot,
            byteCount: entry.byteCount,
            accessTick: accessCounter
        )
        return entry.snapshot
    }

    func remove(profileID: String) {
        mutationCounter &+= 1
        pendingMutationByProfileID[profileID] = mutationCounter
        entriesByProfileID.removeValue(forKey: profileID)
    }

    private func trimIfNeeded() {
        while entriesByProfileID.count > Self.retainedHostLimit,
              let victim = entriesByProfileID.min(by: { $0.value.accessTick < $1.value.accessTick }) {
            entriesByProfileID.removeValue(forKey: victim.key)
        }
    }
}
