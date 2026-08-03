import Foundation
import XCTest
@testable import MimiRemote

@MainActor
final class CarStatusSnapshotTests: XCTestCase {
    func testStatusMappingUsesStablePriority() {
        XCTAssertEqual(snapshot(status: .failed).displayStatus, .failed)
        XCTAssertEqual(snapshot(status: .waitingForApproval).displayStatus, .needsAttention)
        XCTAssertEqual(snapshot(status: .waitingForInput).displayStatus, .needsAttention)
        XCTAssertEqual(snapshot(status: .running).displayStatus, .running)
        XCTAssertEqual(snapshot(status: .completed).displayStatus, .completed)
        XCTAssertEqual(snapshot(status: .closed).displayStatus, .completed)

        for status in [SessionStatus.running, .completed, .closed, .unknown] {
            XCTAssertEqual(
                CarStatusSnapshotV1(
                    profileID: "profile-a",
                    session: makeSession(status: status),
                    isReachable: false,
                    now: referenceDate
                ).displayStatus,
                .offline
            )
        }
        XCTAssertEqual(
            CarStatusSnapshotV1(
                profileID: "profile-a",
                session: makeSession(status: .failed),
                isReachable: false,
                now: referenceDate
            ).displayStatus,
            .failed
        )
        XCTAssertEqual(
            CarStatusSnapshotV1(
                profileID: "profile-a",
                session: makeSession(status: .waitingForApproval),
                isReachable: false,
                now: referenceDate
            ).displayStatus,
            .needsAttention
        )
    }

    func testStaleStatusStartsAtExpirationBoundary() {
        let value = snapshot(status: .running)

        XCTAssertEqual(
            value.effectiveStatus(at: value.expirationDate.addingTimeInterval(-0.001)),
            .running
        )
        XCTAssertEqual(value.effectiveStatus(at: value.expirationDate), .stale)
    }

    func testOldActivityIsFreshWhenJustPublished() {
        let activityDate = referenceDate.addingTimeInterval(-60 * 60)
        let value = CarStatusSnapshotV1(
            profileID: "profile-a",
            session: makeSession(status: .completed, updatedAt: activityDate),
            isReachable: true,
            now: referenceDate
        )

        XCTAssertEqual(value.activityDate, activityDate)
        XCTAssertEqual(value.publishedAt, referenceDate)
        XCTAssertEqual(value.effectiveStatus(at: referenceDate), .completed)
    }

    func testEncodedSnapshotContainsOnlyAllowlistedFields() throws {
        let value = snapshot(status: .waitingForApproval)
        let data = try JSONEncoder().encode(value)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        for forbidden in ["token", "endpoint", "dir", "path", "message", "approval", "input"] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(forbidden), json)
        }
        XCTAssertNotNil(CarStatusSnapshotV1.decode(from: data))
    }

    func testFutureSchemaVersionFailsClosed() throws {
        let data = try JSONEncoder().encode(snapshot(status: .completed))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["schemaVersion"] = 99
        let future = try JSONSerialization.data(withJSONObject: object)

        XCTAssertNil(CarStatusSnapshotV1.decode(from: future))
        XCTAssertNil(CarStatusSnapshotV1.decode(from: Data("broken".utf8)))
    }

    func testCoordinatorDeduplicatesWritesAndClearsSelection() throws {
        let selectionSuite = "CarStatusSnapshotTests.selection.\(UUID().uuidString)"
        let sharedSuite = "CarStatusSnapshotTests.shared.\(UUID().uuidString)"
        let selectionDefaults = try XCTUnwrap(UserDefaults(suiteName: selectionSuite))
        let sharedDefaults = try XCTUnwrap(UserDefaults(suiteName: sharedSuite))
        defer {
            selectionDefaults.removePersistentDomain(forName: selectionSuite)
            sharedDefaults.removePersistentDomain(forName: sharedSuite)
        }

        var reloadCount = 0
        var now = referenceDate
        let coordinator = CarStatusSnapshotCoordinator(
            selectionDefaults: selectionDefaults,
            sharedDefaults: sharedDefaults,
            now: { now },
            reloadTimelines: { reloadCount += 1 }
        )
        let session = makeSession(status: .running)

        coordinator.select(profileID: "profile-a", session: session, isReachable: true)
        XCTAssertEqual(reloadCount, 1)
        XCTAssertEqual(coordinator.storedSnapshot()?.sessionID, session.id)
        XCTAssertEqual(coordinator.storedSnapshot()?.publishedAt, referenceDate)

        now = referenceDate.addingTimeInterval(
            CarStatusSnapshotCoordinator.heartbeatInterval - 1
        )
        coordinator.synchronize(
            profileID: "profile-a",
            sessions: [session],
            isReachable: true
        )
        XCTAssertEqual(reloadCount, 1)
        XCTAssertEqual(coordinator.storedSnapshot()?.publishedAt, referenceDate)

        now = referenceDate.addingTimeInterval(CarStatusSnapshotCoordinator.heartbeatInterval)
        coordinator.synchronize(
            profileID: "profile-a",
            sessions: [session],
            isReachable: true
        )
        XCTAssertEqual(reloadCount, 2)
        XCTAssertEqual(coordinator.storedSnapshot()?.publishedAt, now)

        var renamed = session
        renamed.title = "新的会话标题"
        now = now.addingTimeInterval(1)
        coordinator.synchronize(
            profileID: "profile-a",
            sessions: [renamed],
            isReachable: true
        )
        XCTAssertEqual(reloadCount, 3)
        XCTAssertEqual(coordinator.storedSnapshot()?.publishedAt, now)

        coordinator.clearSelection()
        XCTAssertEqual(reloadCount, 4)
        XCTAssertNil(coordinator.selection)
        XCTAssertNil(coordinator.storedSnapshot())
    }

    func testHostReachabilityRequiresRecentSuccessfulObservation() {
        XCTAssertTrue(
            SessionStore.carStatusHostDidRespond(
                to: AgentAPIError.server(status: 404, message: "workspace missing")
            )
        )
        XCTAssertTrue(
            SessionStore.carStatusHostDidRespond(
                to: AgentAPIError.decoding(DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "invalid payload")
                ))
            )
        )
        XCTAssertFalse(
            SessionStore.carStatusHostDidRespond(to: URLError(.cannotConnectToHost))
        )
        XCTAssertFalse(
            SessionStore.hasRecentCarStatusHostObservation(
                networkStatus: .unknown,
                lastSuccessfulObservationAt: referenceDate,
                now: referenceDate
            )
        )
        XCTAssertFalse(
            SessionStore.hasRecentCarStatusHostObservation(
                networkStatus: .unsatisfied,
                lastSuccessfulObservationAt: referenceDate,
                now: referenceDate
            )
        )
        XCTAssertFalse(
            SessionStore.hasRecentCarStatusHostObservation(
                networkStatus: .satisfied,
                lastSuccessfulObservationAt: nil,
                now: referenceDate
            )
        )
        XCTAssertTrue(
            SessionStore.hasRecentCarStatusHostObservation(
                networkStatus: .satisfied,
                lastSuccessfulObservationAt: referenceDate,
                now: referenceDate.addingTimeInterval(
                    CarStatusSnapshotV1.defaultStaleInterval - 1
                )
            )
        )
        XCTAssertFalse(
            SessionStore.hasRecentCarStatusHostObservation(
                networkStatus: .satisfied,
                lastSuccessfulObservationAt: referenceDate,
                now: referenceDate.addingTimeInterval(
                    CarStatusSnapshotV1.defaultStaleInterval
                )
            )
        )
    }

    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(status: SessionStatus) -> CarStatusSnapshotV1 {
        CarStatusSnapshotV1(
            profileID: "profile-a",
            session: makeSession(status: status),
            isReachable: true,
            now: referenceDate
        )
    }

    private func makeSession(
        status: SessionStatus,
        updatedAt: Date? = nil
    ) -> AgentSession {
        AgentSession(
            id: "session-a",
            projectID: "project-a",
            project: "Mimi Demo",
            dir: "/private/path-that-must-not-be-shared",
            title: "检查会话状态",
            status: status.rawValue,
            source: "codex",
            resumeID: nil,
            createdAt: referenceDate,
            updatedAt: updatedAt ?? referenceDate
        )
    }
}
