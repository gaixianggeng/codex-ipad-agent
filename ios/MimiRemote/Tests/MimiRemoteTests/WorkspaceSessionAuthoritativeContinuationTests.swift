import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testEnsureAuthoritativePresentationFillAutomaticallyResumesSavedCursorAfterBudget() async throws {
        let project = makeProject(id: "workspace_presentation_budget_resume")
        let firstRoot = makeSession(
            id: "presentation_resume_root_0",
            projectID: project.id,
            title: "首个根会话",
            status: "history",
            source: "codex"
        )
        var cursorPages: [String: SessionsPage] = [:]
        for index in 1..<SessionStore.maximumSessionPresentationFillPageCount {
            cursorPages["resume-budget-\(index)"] = SessionsPage(
                sessions: [makeSubagentSession(
                    id: "resume_budget_child_\(index)",
                    projectID: project.id,
                    parentThreadID: firstRoot.id
                )],
                nextCursor: "resume-budget-\(index + 1)",
                hasMore: true
            )
        }
        let remainingRoots = (1..<SessionStore.initialSessionPageLimit).map { index in
            makeSession(
                id: "presentation_resume_root_\(index)",
                projectID: project.id,
                title: "续跑根会话 \(index)",
                status: "history",
                source: "codex"
            )
        }
        cursorPages["resume-budget-12"] = SessionsPage(
            sessions: remainingRoots,
            nextCursor: "resume-older",
            hasMore: true
        )
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(
                sessions: [firstRoot, makeSubagentSession(
                    id: "resume_budget_child_0",
                    projectID: project.id,
                    parentThreadID: firstRoot.id
                )],
                nextCursor: "resume-budget-1",
                hasMore: true
            ),
            cursorPages: cursorPages
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        let workspace = try XCTUnwrap(store.ensureWorkspaceForKnownProjectID(project.id))
        var observedCommittedPartialBeforeResume = false
        client.onSessionPageRequest = { cursor in
            guard cursor == "resume-budget-12" else { return }
            let completion = store.workspaceSessionFirstPageCompletionByKey[
                store.workspaceSessionFirstPageKey(for: workspace)
            ]
            observedCommittedPartialBeforeResume = completion?.consistency == .authoritative
                && completion?.isPresentationWindowComplete == false
                && completion?.continuationCursor == cursor
                && store.sessionPageCursorByProjectID[project.id] == cursor
        }

        try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)

        XCTAssertTrue(observedCommittedPartialBeforeResume, "第二批必须从 Store 已提交的 partial 状态续跑")
        XCTAssertEqual(
            client.requestedSessionCursors,
            [nil]
                + (1..<SessionStore.maximumSessionPresentationFillPageCount).map { "resume-budget-\($0)" }
                + ["resume-budget-12"]
        )
        XCTAssertEqual(store.sessions(forProjectID: project.id).count, SessionStore.initialSessionPageLimit)
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
        XCTAssertNil(
            store.workspaceSessionFirstPageCompletionByKey[
                store.workspaceSessionFirstPageKey(for: workspace)
            ]?.continuationCursor
        )
        XCTAssertNotNil(store.sessionsByID["resume_budget_child_11"], "上一批 child 仍须保留在 canonical Store")
        XCTAssertTrue(store.sessionListFirstPageInFlightByKey.isEmpty)

        let requestCount = client.requestedSessionCursors.count
        try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        XCTAssertEqual(client.requestedSessionCursors.count, requestCount, "完成后再次 ensure 不应新增请求")
    }

    func testEnsureAuthoritativePresentationFillContinuesBeyondOneBurst() async throws {
        let project = makeProject(id: "workspace_presentation_beyond_burst")
        let firstRoot = makeSession(
            id: "presentation_beyond_burst_root_0",
            projectID: project.id,
            title: "首个根会话",
            status: "history",
            source: "codex"
        )
        let pagesBeforeBackoff = SessionStore.maximumSessionPresentationFillPageCount
            * SessionStore.sessionPresentationFillBatchCountPerBurst
        var cursorPages: [String: SessionsPage] = [:]
        for index in 1..<pagesBeforeBackoff {
            cursorPages["beyond-burst-\(index)"] = SessionsPage(
                sessions: [makeSubagentSession(
                    id: "beyond_burst_child_\(index)",
                    projectID: project.id,
                    parentThreadID: firstRoot.id
                )],
                nextCursor: "beyond-burst-\(index + 1)",
                hasMore: true
            )
        }
        let remainingRoots = (1..<SessionStore.initialSessionPageLimit).map { index in
            makeSession(
                id: "presentation_beyond_burst_root_\(index)",
                projectID: project.id,
                title: "续跑根会话 \(index)",
                status: "history",
                source: "codex"
            )
        }
        cursorPages["beyond-burst-\(pagesBeforeBackoff)"] = SessionsPage(
            sessions: remainingRoots,
            nextCursor: "beyond-burst-older",
            hasMore: true
        )
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(
                sessions: [firstRoot, makeSubagentSession(
                    id: "beyond_burst_child_0",
                    projectID: project.id,
                    parentThreadID: firstRoot.id
                )],
                nextCursor: "beyond-burst-1",
                hasMore: true
            ),
            cursorPages: cursorPages
        )
        var requestedSleeps: [UInt64] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionListSleep: { requestedSleeps.append($0) }
        )
        store.projects = [project]

        try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)

        XCTAssertEqual(
            client.requestedSessionCursors,
            [nil] + (1...pagesBeforeBackoff).map { "beyond-burst-\($0)" },
            "跨 burst 必须沿唯一 continuation 前进，不能重新请求 nil"
        )
        XCTAssertEqual(requestedSleeps, [SessionStore.sessionPresentationFillBurstBackoffNanoseconds])
        XCTAssertEqual(store.sessions(forProjectID: project.id).count, SessionStore.initialSessionPageLimit)
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "beyond-burst-older")
        XCTAssertTrue(store.canLoadMoreSessions(projectID: project.id))
    }
}
