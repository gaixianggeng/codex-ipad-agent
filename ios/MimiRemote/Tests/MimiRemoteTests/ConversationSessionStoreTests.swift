import XCTest
import Combine
import Security
import SwiftUI
import UIKit
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testRefreshWithoutRecentWorkspacesDoesNotLoadSessions() async {
        let project = makeProject(id: "proj_no_recent")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = MockSessionStoreClient(projects: [project], sessions: [history])
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)

        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertTrue(store.sidebarProjects.isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(client.requestedProjectIDs.isEmpty)
    }

    func testWorkspaceRecentMapsRootProjectSessionsToWorkspaceID() async {
        let rootProject = makeProject(id: "proj_root")
        let workspace = AgentWorkspace(
            id: "ws_child",
            name: "ios",
            path: "/tmp/\(rootProject.id)/ios",
            rootProjectID: rootProject.id,
            rootProjectName: rootProject.name,
            rootProjectPath: rootProject.path,
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        )
        let childSession = AgentSession(
            id: "codex_child",
            projectID: rootProject.id,
            project: rootProject.name,
            dir: workspace.path,
            title: "子目录会话",
            status: "history",
            source: "codex",
            resumeID: "child",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            projectPages: [
                rootProject.id: SessionsPage(sessions: [childSession])
            ]
        )
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [workspace], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        store.selectedProjectID = workspace.id
        await store.refreshAll(autoAttach: false)

        XCTAssertEqual(client.requestedProjectIDs, [rootProject.id])
        XCTAssertEqual(store.sidebarProjects.map(\.id), [workspace.id])
        XCTAssertEqual(store.sessions(forProjectID: workspace.id).map(\.id), [childSession.id])
        XCTAssertEqual(store.sessions.first?.projectID, workspace.id)
    }

    func testOpenWorkspaceStoresResolvedPathOutsideCandidateList() async {
        let rootProject = makeProject(id: "proj_root")
        let workspace = AgentWorkspace(
            id: "ws_deep_child",
            name: "ios",
            path: "\(rootProject.path)/apps/mobile/ios",
            rootProjectID: rootProject.id,
            rootProjectName: rootProject.name,
            rootProjectPath: rootProject.path
        )
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            projectPages: [
                rootProject.id: SessionsPage(sessions: [])
            ],
            resolveResults: [
                workspace.path: .success(workspace)
            ]
        )
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        let opened = await store.openWorkspace(path: "  \(workspace.path)  ")

        XCTAssertTrue(opened)
        XCTAssertEqual(client.requestedResolvePaths, [workspace.path])
        XCTAssertEqual(client.requestedWorkspaceIDs, [workspace.id])
        XCTAssertEqual(client.requestedProjectIDs, [rootProject.id])
        XCTAssertEqual(store.selectedProjectID, workspace.id)
        XCTAssertEqual(store.sidebarProjects.map(\.id), [workspace.id])
        XCTAssertNil(store.errorMessage)
    }

    func testDirectoryListResponseDecodesAgentdPayload() throws {
        let json = """
        {
          "path": "/Users/me",
          "parent_path": null,
          "entries": [
            {"name": "finance", "path": "/Users/me/finance", "is_dir": true, "can_open": true, "can_browse": true}
          ]
        }
        """
        let response = try JSONDecoder().decode(DirectoryListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.path, "/Users/me")
        XCTAssertNil(response.parentPath)
        XCTAssertEqual(response.entries.map(\.name), ["finance"])
        XCTAssertEqual(response.entries.first?.path, "/Users/me/finance")
        XCTAssertEqual(response.entries.first?.canOpen, true)
        XCTAssertEqual(response.entries.first?.canBrowse, true)
        XCTAssertNil(response.truncated)
    }

    func testListDirectoriesUsesInjectedClientAndKeepsErrorsLocal() async throws {
        let rootProject = makeProject(id: "proj_root")
        let listing = DirectoryListResponse(
            path: rootProject.path,
            parentPath: nil,
            entries: [
                DirectoryEntry(name: "finance", path: "\(rootProject.path)/finance", isDir: true, canOpen: true, canBrowse: true)
            ],
            truncated: nil
        )
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            directoryListResults: [
                "": .success(listing),
                "/forbidden": .failure(AgentAPIError.server(status: 403, message: "路径不在允许范围内或不可访问"))
            ]
        )
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        let response = try await store.listDirectories(path: "")
        XCTAssertEqual(response, listing)

        do {
            _ = try await store.listDirectories(path: "/forbidden")
            XCTFail("allowlist 外目录应抛错")
        } catch {
            // 浏览错误应抛给调用方内联展示，不污染全局 errorMessage。
        }
        XCTAssertEqual(client.requestedDirectoryPaths, ["", "/forbidden"])
        XCTAssertNil(store.errorMessage)
    }

    func testSessionStorePinsAndArchivesSessionsLocally() async {
        let project = makeProject(id: "proj_prefs")
        let older = makeSession(
            id: "session_older",
            projectID: project.id,
            title: "旧会话",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = makeSession(
            id: "session_newer",
            projectID: project.id,
            title: "新会话",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectPages: [
                project.id: SessionsPage(sessions: [older, newer])
            ],
            sessionArchiveResults: [
                older.id: .success(())
            ]
        )
        let appStore = AppStore()
        let preferences = makeSessionListPreferenceStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [AgentWorkspace(project: project)], endpoint: appStore.endpoint),
            sessionListPreferenceStore: preferences,
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [newer.id, older.id])

        store.toggleSessionPinned(older)
        XCTAssertTrue(store.isSessionPinned(older.id))
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [older.id, newer.id])
        XCTAssertEqual(preferences.load(endpoint: appStore.endpoint).pinnedSessionIDs, [older.id])

        await store.toggleSessionArchivedRemote(older)
        XCTAssertFalse(store.isSessionPinned(older.id))
        XCTAssertTrue(store.isSessionArchived(older.id))
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [newer.id])
        XCTAssertEqual(preferences.load(endpoint: appStore.endpoint).archivedSessionIDs, [older.id])

        await store.toggleSessionArchivedRemote(older)
        XCTAssertFalse(store.isSessionArchived(older.id))
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [newer.id, older.id])
        XCTAssertEqual(client.requestedSessionArchives, [
            RequestedSessionArchive(id: older.id, archived: true),
            RequestedSessionArchive(id: older.id, archived: false)
        ])
    }

    func testSessionStoreSchedulesAndClearsLocalReminder() async throws {
        let project = makeProject(id: "proj_reminder")
        let session = makeSession(
            id: "session_reminder",
            projectID: project.id,
            title: "检查结果",
            status: "history",
            source: "codex"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectPages: [
                project.id: SessionsPage(sessions: [session])
            ]
        )
        let appStore = AppStore()
        let reminderStore = makeSessionReminderStore()
        let scheduler = FakeSessionReminderScheduler()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [AgentWorkspace(project: project)], endpoint: appStore.endpoint),
            sessionReminderStore: reminderStore,
            sessionReminderScheduler: scheduler,
            clientFactory: { client }
        )
        let now = Date(timeIntervalSince1970: 1_000)

        await store.refreshAll(autoAttach: false)
        await store.scheduleSessionReminder(session, after: 30 * 60, now: now)

        let reminder = try XCTUnwrap(store.sessionReminder(for: session.id))
        XCTAssertEqual(reminder.sessionID, session.id)
        XCTAssertEqual(reminder.title, session.title)
        XCTAssertEqual(reminder.fireAt, now.addingTimeInterval(30 * 60))
        XCTAssertEqual(scheduler.scheduled, [reminder])
        XCTAssertEqual(reminderStore.load(endpoint: appStore.endpoint)[session.id], reminder)

        store.clearSessionReminder(session)

        XCTAssertNil(store.sessionReminder(for: session.id))
        XCTAssertEqual(scheduler.canceledSessionIDs, [session.id])
        XCTAssertTrue(reminderStore.load(endpoint: appStore.endpoint).isEmpty)
    }

    func testSessionReminderPermissionDeniedKeepsLocalStateButPastRequestDoesNotPersist() async throws {
        let project = makeProject(id: "proj_reminder_permission")
        let session = makeSession(
            id: "session_reminder_permission",
            projectID: project.id,
            title: "检查权限结果",
            status: "history",
            source: "codex"
        )
        let appStore = AppStore()
        let reminderStore = makeSessionReminderStore()
        let scheduler = FakeSessionReminderScheduler(scheduleOutcome: .permissionDenied)
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionReminderStore: reminderStore,
            sessionReminderScheduler: scheduler,
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [session]) }
        )
        let now = Date()

        await store.scheduleSessionReminder(session, after: 30 * 60, now: now)

        let saved = try XCTUnwrap(store.sessionReminder(for: session.id))
        XCTAssertEqual(reminderStore.load(endpoint: appStore.endpoint)[session.id], saved)
        XCTAssertEqual(scheduler.scheduled, [saved])
        XCTAssertEqual(store.statusMessage, L10n.text("ui.the_in_app_reminder_has_been_saved_the"))
        XCTAssertNotEqual(store.statusMessage, L10n.format("ui.reminder_value_has_been_set", session.title))

        await store.scheduleSessionReminder(session, after: -1, now: now)

        XCTAssertNil(store.sessionReminder(for: session.id))
        XCTAssertTrue(reminderStore.load(endpoint: appStore.endpoint).isEmpty)
        XCTAssertEqual(scheduler.scheduled, [saved], "已过期请求不能再进入系统通知调度")
        XCTAssertEqual(scheduler.canceledSessionIDs, [session.id])
        XCTAssertEqual(store.statusMessage, L10n.format("ui.the_reminder_time_has_passed_and_the_reminder", session.title))
    }

    func testSessionReminderReloadAndForegroundPruneExpiredStateWithoutTimer() async throws {
        let suiteName = "ConversationDataFlowTests.ReminderPrune.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
        let reminderStore = SessionReminderStore(defaults: defaults, key: "test.sessionReminders")
        var now = Date(timeIntervalSince1970: 1_000)
        let expiredAtReload = SessionReminder(
            sessionID: "reminder_expired_reload",
            title: "启动前已到期",
            fireAt: now.addingTimeInterval(-1),
            createdAt: now.addingTimeInterval(-100)
        )
        let expiresInBackground = SessionReminder(
            sessionID: "reminder_expires_background",
            title: "后台期间到期",
            fireAt: now.addingTimeInterval(60),
            createdAt: now
        )
        reminderStore.save(
            [
                expiredAtReload.sessionID: expiredAtReload,
                expiresInBackground.sessionID: expiresInBackground
            ],
            endpoint: appStore.endpoint
        )
        let scheduler = FakeSessionReminderScheduler()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionReminderStore: reminderStore,
            sessionReminderScheduler: scheduler,
            sessionReminderNow: { now },
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )

        XCTAssertNil(store.sessionReminder(for: expiredAtReload.sessionID))
        XCTAssertEqual(store.sessionReminder(for: expiresInBackground.sessionID), expiresInBackground)
        XCTAssertEqual(
            reminderStore.load(endpoint: appStore.endpoint),
            [expiresInBackground.sessionID: expiresInBackground]
        )
        XCTAssertEqual(scheduler.canceledSessionIDs, [expiredAtReload.sessionID])

        now = now.addingTimeInterval(120)
        await store.resumeFromForeground()

        XCTAssertNil(store.sessionReminder(for: expiresInBackground.sessionID))
        XCTAssertTrue(reminderStore.load(endpoint: appStore.endpoint).isEmpty)
        XCTAssertEqual(
            scheduler.canceledSessionIDs,
            [expiredAtReload.sessionID, expiresInBackground.sessionID]
        )
    }

    func testNotificationPayloadUsesActiveProfileAndCurrentMacRefreshSelectsSession() async throws {
        let suiteName = "ConversationDataFlowTests.NotificationCurrentProfile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-current",
            displayName: "当前 Mac",
            endpoint: "http://100.64.0.10:8787",
            lastSuccessfulAt: nil
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v1")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("current-secret-token".utf8), account: "agentd-profile.\(profile.id)")
        let appStore = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        let project = makeProject(id: "proj_notification_current")
        let session = makeSession(
            id: "session_notification_current",
            projectID: project.id,
            title: "通知打开目标",
            status: "history",
            source: "codex"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectPages: [project.id: SessionsPage(sessions: [session])]
        )
        let scheduler = FakeSessionReminderScheduler()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionReminderScheduler: scheduler,
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )

        await store.scheduleSessionReminder(session, after: 600, now: Date(timeIntervalSince1970: 1_000))
        let route = try XCTUnwrap(scheduler.reminderRoutes.first)
        XCTAssertEqual(route.version, SessionNotificationRoute.currentVersion)
        XCTAssertEqual(route.profileID, profile.id)
        XCTAssertEqual(route.projectID, project.id)
        XCTAssertEqual(route.sessionID, session.id)
        XCTAssertEqual(SessionNotificationRoute(userInfo: route.userInfo), route)
        XCTAssertFalse(String(describing: route.userInfo).contains("current-secret-token"), "系统通知 payload 绝不能包含 Token")

        let outcome = await store.openSessionFromNotification(route)

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertEqual(store.selectedSessionID, session.id)
        XCTAssertEqual(client.requestedProjectIDs, [project.id], "暂未加载时只做一次当前工作区首屏刷新")
        XCTAssertEqual(appStore.activeConnectionProfileID, profile.id)
    }

    func testNotificationFromOtherMacOnlyPromptsForProfileSwitch() async throws {
        let suiteName = "ConversationDataFlowTests.NotificationOtherProfile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = [
            ConnectionProfile(id: "mac-a", displayName: "当前 Mac", endpoint: "http://100.64.0.10:8787", lastSuccessfulAt: nil),
            ConnectionProfile(id: "mac-b", displayName: "备用 Mac", endpoint: "http://100.64.0.20:8787", lastSuccessfulAt: nil)
        ]
        defaults.set(try JSONEncoder().encode(profiles), forKey: "agentd.connectionProfiles.v1")
        defaults.set(profiles[0].id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profiles[0].endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        keychain.setData(Data("token-b".utf8), account: "agentd-profile.mac-b")
        let appStore = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        let client = MockSessionStoreClient(projects: [], sessions: [])
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        let generationBeforeTap = appStore.connectionGeneration
        let route = SessionNotificationRoute.current(
            profileID: "mac-b",
            projectID: "proj_other_mac",
            sessionID: "session_other_mac"
        )

        let outcome = await store.openSessionFromNotification(route)

        XCTAssertEqual(outcome, .requiresProfileSwitch(displayName: "备用 Mac"))
        XCTAssertEqual(appStore.activeConnectionProfileID, "mac-a")
        XCTAssertEqual(appStore.connectionGeneration, generationBeforeTap)
        XCTAssertNil(store.selectedSessionID)
        XCTAssertTrue(client.requestedProjectIDs.isEmpty, "错 Mac 通知不能向当前或目标 Mac 发任何会话请求")
        XCTAssertTrue(store.statusMessage?.contains("切换连接档案") == true)
    }

    func testNotificationResponseAdapterKeepsColdStartPendingAndIgnoresMalformedPayload() throws {
        let adapter = SessionNotificationResponseAdapter()
        XCTAssertFalse(adapter.receive(userInfo: [
            "mimi.route.sessionID": "legacy-session"
        ]))
        XCTAssertFalse(adapter.receive(userInfo: [
            "mimi.route.version": 0,
            "mimi.route.profileID": "mac-a",
            "mimi.route.projectID": "proj-a",
            "mimi.route.sessionID": "session-a"
        ]))
        XCTAssertNil(adapter.pendingRoute, "旧版或畸形 payload 必须安全忽略")

        let route = SessionNotificationRoute.current(
            profileID: "mac-a",
            projectID: "proj-a",
            sessionID: "session-a"
        )
        XCTAssertTrue(adapter.receive(userInfo: route.userInfo))
        XCTAssertEqual(adapter.pendingRoute, route, "冷启动时消费者尚未建立也必须保留一次点击路由")

        adapter.consume(route)
        XCTAssertNil(adapter.pendingRoute)
        adapter.consume(route)
        XCTAssertNil(adapter.pendingRoute, "已消费路由不能重复触发")
    }

    func testPreviewFileWritesDecodedPayloadToTemporaryFile() async throws {
        let filePath = "/repo/report.pdf"
        let payload = Data("preview-payload".utf8)
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            fileReadResults: [
                filePath: .success(FileReadResponse(
                    path: filePath,
                    name: "../report.pdf",
                    contentType: "application/pdf",
                    size: Int64(payload.count),
                    contentBase64: payload.base64EncodedString()
                ))
            ]
        )
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        let url = try await store.previewFile(path: filePath)
        XCTAssertEqual(client.requestedFileReadPaths, [filePath])
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-report.pdf"))
        XCTAssertNil(store.errorMessage)
    }

    func testPreviewHistoryMediaWritesDecodedPayloadToTemporaryFile() async throws {
        let mediaID = "media-123"
        let payload = Data("history-image-payload".utf8)
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            historyMediaResults: [
                mediaID: .success(FileReadResponse(
                    path: "agentd-history-media://\(mediaID)",
                    name: "history-image.png",
                    contentType: "image/png",
                    size: Int64(payload.count),
                    contentBase64: payload.base64EncodedString()
                ))
            ]
        )
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        let url = try await store.previewHistoryMedia(id: mediaID)
        XCTAssertEqual(client.requestedHistoryMediaIDs, [mediaID])
        XCTAssertEqual(client.requestedFileReadPaths, [])
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-history-image.png"))
        XCTAssertNil(store.errorMessage)
    }

    func testWorkspaceLoadFailureMarksUnavailableWhenResolveRejects() async {
        let rootProject = makeProject(id: "proj_root")
        let workspace = makeChildWorkspace(id: "ws_gone", name: "gone", root: rootProject)
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            workspaceSessionsError: [workspace.id: AgentAPIError.server(status: 403, message: "cwd 必须来自 projects allowlist")],
            resolveResults: [workspace.path: .failure(AgentAPIError.server(status: 403, message: "路径不在允许范围内或不可访问"))]
        )
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [workspace], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        store.selectedProjectID = workspace.id
        await store.refreshAll(autoAttach: false)

        // 会话加载失败 + resolve 明确 4xx → 单独标记该工作区不可用，且不冒泡成全局错误。
        XCTAssertTrue(store.isWorkspaceUnavailable(workspace.id))
        XCTAssertEqual(client.requestedResolvePaths, [workspace.path])
        XCTAssertNil(store.errorMessage)
    }

    func testWorkspaceLoadFailureStaysTransientWhenResolveSucceeds() async {
        let rootProject = makeProject(id: "proj_root")
        let workspace = makeChildWorkspace(id: "ws_flaky", name: "flaky", root: rootProject)
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            workspaceSessionsError: [workspace.id: AgentAPIError.server(status: 502, message: "连接 app-server gateway 上游失败")],
            resolveResults: [workspace.path: .success(workspace)]
        )
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [workspace], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        store.selectedProjectID = workspace.id
        await store.refreshAll(autoAttach: false)

        // resolve 仍成功 → 判定为瞬时故障：不标记不可用，仍按普通错误处理以便重试。
        XCTAssertFalse(store.isWorkspaceUnavailable(workspace.id))
        XCTAssertEqual(client.requestedResolvePaths, [workspace.path])
        XCTAssertNotNil(store.errorMessage)
    }

    func testForgetWorkspaceClearsUnavailableMark() async {
        let rootProject = makeProject(id: "proj_root")
        let workspace = makeChildWorkspace(id: "ws_gone", name: "gone", root: rootProject)
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            workspaceSessionsError: [workspace.id: AgentAPIError.server(status: 403, message: "denied")],
            resolveResults: [workspace.path: .failure(AgentAPIError.server(status: 403, message: "denied"))]
        )
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [workspace], endpoint: appStore.endpoint),
            clientFactory: { client }
        )

        store.selectedProjectID = workspace.id
        await store.refreshAll(autoAttach: false)
        XCTAssertTrue(store.isWorkspaceUnavailable(workspace.id))

        store.forgetWorkspace(workspace.project)

        XCTAssertFalse(store.isWorkspaceUnavailable(workspace.id))
        XCTAssertTrue(store.sidebarProjects.isEmpty)
    }

    func testSessionStoreAutoAttachKeepsExplicitHistorySelection() async {
        let project = makeProject(id: "proj_1")
        let selectedHistory = makeSession(id: "codex_selected", projectID: project.id, title: "用户点选的历史", status: "history", source: "codex", resumeID: "selected")
        let latestRunning = makeSession(id: "sess_latest", projectID: project.id, title: "最新运行会话", status: "running", source: "codex")
        let client = MockSessionStoreClient(projects: [project], sessions: [latestRunning, selectedHistory])
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        XCTAssertNil(store.selectedSessionID)
        await store.selectSession(selectedHistory)
        await store.refreshAll(autoAttach: true)

        XCTAssertEqual(client.requestedProjectIDs.compactMap { $0 }, [project.id])
        XCTAssertEqual(store.selectedSessionID, selectedHistory.id)
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertTrue(conversationStore.hasLoadedHistory(sessionID: selectedHistory.id))
    }

    func testSessionStoreAutoAttachRefreshesRunningSessionWithoutSelectingIt() async throws {
        let project = makeProject(id: "proj_auto_attach")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史会话", status: "history", source: "codex", resumeID: "history")
        let running = makeSession(id: "sess_auto_running", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let client = MockSessionStoreClient(projects: [project], sessions: [history, running])
        var sockets: [MockWebSocketClient] = []
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project, lastOpenedAt: Date(timeIntervalSince1970: 10))],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: true)

        XCTAssertNil(store.selectedSessionID)
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertFalse(store.isSelectedSessionObserving)
        XCTAssertTrue(sockets.isEmpty)
        XCTAssertEqual(store.webSocketStatus, .disconnected)
    }

    func testForegroundResumeKeepsSessionListVisibleWhenRunningSessionExists() async {
        let project = makeProject(id: "proj_foreground_list")
        let running = makeSession(
            id: "sess_foreground_list",
            projectID: project.id,
            title: "运行中",
            status: "running",
            source: "codex"
        )
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project)],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: true)
        store.suspendForBackground()
        await store.resumeFromForeground()

        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertNil(store.selectedSessionID)
        XCTAssertTrue(sockets.isEmpty)
        XCTAssertEqual(store.webSocketStatus, .disconnected)
    }

    func testBootstrapRestoresOnlyExplicitRunningSessionAndCreatesOneSocket() async {
        let project = makeProject(id: "proj_explicit_restore")
        let requested = makeSession(
            id: "sess_explicit_restore",
            projectID: project.id,
            title: "明确恢复的详情",
            status: "running",
            source: "codex"
        )
        let otherRunning = makeSession(
            id: "sess_other_running",
            projectID: project.id,
            title: "不能抢导航",
            status: "running",
            source: "codex"
        )
        let appStore = AppStore()
        appStore.token = "test-token"
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [otherRunning, requested],
            messagesResult: []
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project)],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )
        store.takeOverSession(requested)
        let snapshot = SessionRestoreSnapshot(endpoint: appStore.endpoint, session: requested)

        let didRestore = await store.bootstrap(restoring: snapshot)

        XCTAssertTrue(didRestore)
        XCTAssertEqual(store.selectedSessionID, requested.id)
        XCTAssertEqual(store.selectedProjectID, requested.projectID)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(sockets.first?.connectedSessionIDs, [requested.id])
    }

    func testWorkbenchRestorationRouteRoundTripsLocalSessionIDAndSourcePage() throws {
        let route = WorkbenchRestorationRoute.session(
            id: "local:claude:thread:123",
            source: .workspaces
        )

        XCTAssertEqual(
            WorkbenchRestorationRoute(storageValue: route.storageValue),
            route
        )
    }

    func testWorkbenchNavigationDeduplicatesRepeatedSessionOpen() {
        var state = WorkbenchNavigationState(route: .workspaces)
        let event = WorkbenchNavigationEvent.open(.session("session-1"), source: .workspaces)

        let firstEffect = state.reduce(
            event,
            usesCompactNavigation: true,
            selectedSessionID: nil
        )
        let stateAfterFirstOpen = state
        let routeAfterFirstOpen = state.route
        let routeFeedbackEffect = state.reduce(
            .synchronize(routeAfterFirstOpen),
            usesCompactNavigation: true,
            selectedSessionID: nil
        )
        let repeatedEffect = state.reduce(
            event,
            usesCompactNavigation: true,
            selectedSessionID: nil
        )

        XCTAssertEqual(firstEffect, .selectSession("session-1"))
        XCTAssertNil(routeFeedbackEffect)
        XCTAssertNil(repeatedEffect)
        XCTAssertEqual(state, stateAfterFirstOpen)
        XCTAssertEqual(state.route, .session(id: "session-1", source: .workspaces))
        XCTAssertEqual(state.compactWorkspacePath, [.session("session-1")])
    }

    func testWorkbenchNavigationCreatedSessionCallbackDoesNotOpenTwice() {
        var state = WorkbenchNavigationState(route: .workspaces)

        let selectionEffect = state.reduce(
            .selectedSessionChanged("local:new-session"),
            usesCompactNavigation: true,
            selectedSessionID: "local:new-session"
        )
        let stateAfterSelection = state
        let callbackEffect = state.reduce(
            .open(.session("local:new-session"), source: nil),
            usesCompactNavigation: true,
            selectedSessionID: "local:new-session"
        )

        XCTAssertNil(selectionEffect)
        XCTAssertNil(callbackEffect)
        XCTAssertEqual(state, stateAfterSelection)
        XCTAssertEqual(state.compactWorkspacePath, [.session("local:new-session")])
    }

    func testWorkbenchNavigationSplitSelectionPreservesWorkspaceSource() {
        var state = WorkbenchNavigationState(route: .workspaces)

        let effect = state.reduce(
            .selectedSessionChanged("workspace-session"),
            usesCompactNavigation: false,
            selectedSessionID: "workspace-session"
        )

        XCTAssertNil(effect)
        XCTAssertEqual(
            state.route,
            .session(id: "workspace-session", source: .workspaces)
        )
        XCTAssertEqual(state.selection, .session("workspace-session"))
    }

    func testWorkbenchNavigationCompactWorkspacePopReturnsToWorkspace() {
        var state = WorkbenchNavigationState(
            route: .session(id: "session-workspace", source: .workspaces)
        )

        let effect = state.reduce(
            .compactPathChanged(tab: .workspaces, path: []),
            usesCompactNavigation: true,
            selectedSessionID: "session-workspace"
        )

        XCTAssertEqual(effect, .returnToSessionList)
        XCTAssertEqual(state.route, .workspaces)
        XCTAssertEqual(state.selection, .workspaces)
        XCTAssertEqual(state.compactSelectedTab, .workspaces)
        XCTAssertTrue(state.compactWorkspacePath.isEmpty)
    }

    func testWorkbenchNavigationRestoresSessionIntoItsSourceStack() {
        var state = WorkbenchNavigationState()
        let route = WorkbenchRestorationRoute.session(
            id: "restored-session",
            source: .workspaces
        )

        let effect = state.reduce(
            .synchronize(route),
            usesCompactNavigation: true,
            selectedSessionID: "restored-session"
        )

        XCTAssertNil(effect)
        XCTAssertEqual(state.route, route)
        XCTAssertEqual(state.selection, .session("restored-session"))
        XCTAssertEqual(state.compactSelectedTab, .workspaces)
        XCTAssertEqual(state.compactWorkspacePath, [.session("restored-session")])
        XCTAssertTrue(state.compactSessionPath.isEmpty)
    }

    func testWorkbenchNavigationReplacesOptimisticSessionWithoutAddingStackLevel() {
        var state = WorkbenchNavigationState(route: .sessions)

        _ = state.reduce(
            .selectedSessionChanged("local:optimistic"),
            usesCompactNavigation: true,
            selectedSessionID: "local:optimistic"
        )
        _ = state.reduce(
            .selectedSessionChanged("server-session"),
            usesCompactNavigation: true,
            selectedSessionID: "server-session"
        )

        XCTAssertEqual(state.route, .session(id: "server-session", source: .sessions))
        XCTAssertEqual(state.compactSessionPath, [.session("server-session")])
    }

    func testWorkbenchRestorationRouteRejectsMismatchedSessionSnapshot() throws {
        let session = makeSession(
            id: "session_snapshot",
            projectID: "project_snapshot",
            title: "恢复快照",
            status: "history",
            source: "codex",
            resumeID: "resume_snapshot"
        )
        let snapshot = SessionRestoreSnapshot(endpoint: "http://127.0.0.1:8787", session: session)
        let storage = try JSONEncoder().encode(snapshot).base64EncodedString()
        let route = WorkbenchRestorationRoute.session(id: "another_session", source: .sessions)

        XCTAssertNil(route.restoreSnapshot(from: storage, currentEndpoint: snapshot.endpoint))
    }

    func testWorkbenchRestorationRouteRejectsSnapshotFromDifferentEndpoint() throws {
        let session = makeSession(
            id: "session_endpoint",
            projectID: "project_endpoint",
            title: "旧 Mac 快照",
            status: "history",
            source: "codex",
            resumeID: "resume_endpoint"
        )
        let snapshot = SessionRestoreSnapshot(endpoint: "http://100.64.0.10:8787", session: session)
        let storage = try JSONEncoder().encode(snapshot).base64EncodedString()
        let route = WorkbenchRestorationRoute.session(id: session.id, source: .sessions)

        XCTAssertNil(route.restoreSnapshot(from: storage, currentEndpoint: "http://100.64.0.11:8787"))
    }

    func testSelectingRunningSessionRefreshesHistoryAndSuppressesBufferedMessageReplay() async throws {
        let project = makeProject(id: "proj_live_resume")
        let running = makeSession(id: "sess_live_resume", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let refreshedHistory = [
            CodexHistoryMessage(
                id: "live-user",
                role: "user",
                content: "开始长任务",
                createdAt: Date(timeIntervalSince1970: 10)
            ),
            CodexHistoryMessage(
                id: "live-assistant",
                role: "assistant",
                content: "离开期间已经完成的最新回答",
                createdAt: Date(timeIntervalSince1970: 20),
                updatedAt: Date(timeIntervalSince1970: 30),
                turnID: "turn-live",
                itemID: "assistant-live",
                sendStatus: .confirmed
            )
        ]
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            historyPages: [running.id: HistoryMessagesPage(messages: refreshedHistory)]
        )
        let conversationStore = ConversationStore()
        conversationStore.setHistory([
            CodexHistoryMessage(
                id: "stale-assistant",
                role: "assistant",
                content: "旧回答",
                createdAt: Date(timeIntervalSince1970: 1)
            )
        ], sessionID: running.id)
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.takeOverSession(running)
        await store.selectSession(running)

        XCTAssertEqual(client.requestedMessageSessionIDs, [running.id])
        XCTAssertEqual(client.requestedMessageCursors, [nil])
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(sockets[0].replayBufferedEventsByConnect, [false])
        XCTAssertEqual(conversationStore.messages(for: running.id).suffix(refreshedHistory.count).map(\.content), refreshedHistory.map(\.content))
    }

    func testSessionStoreSendsUserInputAnswersThroughExistingSocket() async throws {
        let project = makeProject(id: "proj_user_input")
        let request = AgentUserInputRequest(
            id: "input-1",
            threadID: "sess_user_input",
            turnID: "turn-1",
            itemID: "input-1",
            questions: [
                AgentUserInputQuestion(
                    id: "scope",
                    header: "范围",
                    question: "先做哪一部分？",
                    isOther: true,
                    isSecret: false,
                    options: [AgentUserInputOption(label: "后端", description: "先落 API")]
                )
            ]
        )
        let running = AgentSession(
            id: request.threadID,
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: "等待引导",
            status: "waiting_for_input",
            source: "codex",
            resumeID: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            pendingUserInput: request
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        let conversationStore = ConversationStore()
        conversationStore.appendSystem("等待补充信息：\(request.title)", sessionID: running.id, kind: .userInput)
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        for _ in 0..<50 where sockets.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(sockets.count, 1)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        store.respondToUserInput(request, answers: ["scope": ["后端", "只做最小闭环"]])

        XCTAssertEqual(sockets[0].sentUserInputResponses.count, 1)
        XCTAssertEqual(sockets[0].sentUserInputResponses.first?.requestID, "input-1")
        XCTAssertEqual(sockets[0].sentUserInputResponses.first?.answers["scope"], ["后端", "只做最小闭环"])
        XCTAssertTrue(store.isUserInputResponsePending(request))
        XCTAssertEqual(store.selectedSession?.status, "running")
        XCTAssertNil(store.selectedSession?.pendingUserInput)
        XCTAssertEqual(conversationStore.messages(for: running.id).last?.content, "补充信息已提交：范围")

        await store.refreshAll(autoAttach: false)

        XCTAssertEqual(store.selectedSession?.status, "running")
        XCTAssertNil(store.selectedSession?.pendingUserInput)

        sockets[0].onUserInputResponseFailure?("input-1", "request expired")
        try await waitForSelectedSessionStatus("waiting_for_input", store: store)

        XCTAssertEqual(store.selectedSession?.pendingUserInput, request)
        XCTAssertFalse(store.isUserInputResponsePending(request))
        XCTAssertEqual(conversationStore.messages(for: running.id).last?.content, "等待补充信息：范围")
    }

    func testSessionStoreReturnToListDoesNotPublishWhenAlreadyCleared() {
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        var publishCount = 0
        var cancellables: Set<AnyCancellable> = []

        store.objectWillChange
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        // 已经处于会话列表页时再次返回，不应重复写入 nil/disconnected 状态刷新整棵侧栏 UI。
        store.returnToSessionList()

        XCTAssertEqual(publishCount, 0)
    }

    func testSelectingAlreadySelectedHistoryDoesNotPublishWhenHistoryLoaded() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let conversationStore = ConversationStore()
        conversationStore.setHistory([
            CodexHistoryMessage(id: "rollout:1", role: "assistant", content: "已加载", createdAt: Date(timeIntervalSince1970: 1))
        ], sessionID: history.id)
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [history]) },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )
        store.selectedProjectID = project.id
        store.selectedSessionID = history.id
        await store.toggleProjectExpansion(project)
        // 历史会话的稳态现在包含事件订阅：先完整选择一次并让 socket 连上，
        // 再排空静默补拉任务，进入稳态后重复点选才是 no-op。
        await store.selectSession(history)
        sockets.last?.emitStatus(.connected)
        for _ in 0..<10 {
            await Task.yield()
        }
        var publishCount = 0
        var cancellables: Set<AnyCancellable> = []

        store.objectWillChange
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        // Codex/litter 都避免 no-op diff 继续下发事件；重复点当前历史行也不应刷新侧栏。
        await store.selectSession(history)

        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertEqual(store.selectedSessionID, history.id)
        XCTAssertEqual(sockets.count, 1)
    }

    func testSelectingHistorySessionKeepsSelectionWhenMessages404() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_missing", projectID: project.id, title: "缺失 rollout", status: "history", source: "codex", resumeID: "missing")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            messagesError: AgentAPIError.server(status: 404, message: "读取 Codex 历史失败")
        )
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)

        XCTAssertEqual(client.requestedMessageSessionIDs, [history.id])
        XCTAssertEqual(store.selectedSessionID, history.id)
        XCTAssertFalse(conversationStore.hasLoadedHistory(sessionID: history.id))
        XCTAssertTrue(store.statusMessage?.contains("HTTP 404") == true)
    }

    func testSelectingHistorySessionKeepsSelectionWhenNoRolloutFound() async {
        let project = makeProject(id: "proj_no_rollout")
        let history = makeSession(
            id: "codex_no_rollout",
            projectID: project.id,
            title: "缺失 rollout",
            status: "history",
            source: "codex",
            resumeID: "missing-rollout"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            messagesError: AgentAPIError.server(status: 404, message: "no rollout found")
        )
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)

        XCTAssertEqual(client.requestedMessageSessionIDs, [history.id])
        XCTAssertEqual(store.selectedSessionID, history.id)
        XCTAssertFalse(conversationStore.hasLoadedHistory(sessionID: history.id))
        // 历史读取失败只影响历史面板，不应把会话选择清掉或伪装成仍在运行的 turn。
        XCTAssertTrue(store.statusMessage?.contains("no rollout found") == true)
        XCTAssertNil(store.selectedForegroundActivity)
    }

    func testSendingPromptToCodexHistoryResumesAndKeepsLocalHiMessage() async throws {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            createSessionResponse: try makeCreateSessionResponse(session: history)
        )
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)
        await store.sendPrompt("hi")

        XCTAssertEqual(client.createPayloads.count, 1)
        XCTAssertEqual(client.createPayloads.first?.resumeID, history.resumeID)
        XCTAssertEqual(client.createPayloads.first?.prompt, "hi")
        let messages = conversationStore.messages(for: history.id)
        XCTAssertTrue(messages.contains { $0.role == .user && $0.content == "历史问题" })
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.content == "历史回答" })
        XCTAssertTrue(messages.contains { $0.role == .user && $0.content == "hi" && $0.sendStatus == .sent })
    }

    func testSessionStoreProjectSelectionRefreshesProjectHistoryWithoutSelectingLatest() async {
        let firstProject = makeProject(id: "proj_1")
        let freshHistory = makeSession(id: "codex_fresh", projectID: firstProject.id, title: "刷新后的历史", status: "history", source: "codex", resumeID: "fresh")
        let client = MockSessionStoreClient(
            projects: [firstProject],
            sessions: [],
            projectSessions: [firstProject.id: [freshHistory]]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.selectProject(firstProject)

        XCTAssertEqual(client.requestedProjectIDs, [firstProject.id])
        XCTAssertEqual(store.filteredSessions.map(\.id), [freshHistory.id])
        XCTAssertNil(store.selectedSessionID)
    }

    func testWorkspaceCatalogRefreshDoesNotChangeActiveSessionContext() async throws {
        let project = makeProject(id: "proj_catalog_refresh")
        let session = makeSession(
            id: "sess_catalog_refresh",
            projectID: project.id,
            title: "正在查看的会话",
            status: "history",
            source: "codex",
            resumeID: "catalog-refresh"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            messagesResult: []
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectProject(project)
        await store.selectSession(session)
        let selectedProjectID = store.selectedProjectID
        let selectedSessionID = store.selectedSessionID
        let socketCount = sockets.count

        try await store.refreshWorkspaceCatalog()

        XCTAssertEqual(store.selectedProjectID, selectedProjectID)
        XCTAssertEqual(store.selectedSessionID, selectedSessionID)
        XCTAssertEqual(sockets.count, socketCount)
        XCTAssertEqual(store.sidebarProjects.map(\.id), [project.id])
    }

    func testWorkspaceSessionRefreshLoadsBrowsedWorkspaceWithoutChangingActiveSession() async throws {
        let activeProject = makeProject(id: "proj_active_session")
        let browsedProject = makeProject(id: "proj_browsed_workspace")
        let activeSession = makeSession(
            id: "sess_active_session",
            projectID: activeProject.id,
            title: "正在运行的会话",
            status: "running",
            source: "codex",
            resumeID: "active-session"
        )
        let browsedSession = makeSession(
            id: "sess_browsed_workspace",
            projectID: browsedProject.id,
            title: "首次进入即可看到的会话",
            status: "history",
            source: "codex",
            resumeID: "browsed-session"
        )
        let appStore = AppStore()
        let recentStore = makeRecentWorkspaceStore(
            workspaces: [
                AgentWorkspace(project: activeProject, lastOpenedAt: Date(timeIntervalSince1970: 20)),
                AgentWorkspace(project: browsedProject, lastOpenedAt: Date(timeIntervalSince1970: 10))
            ],
            endpoint: appStore.endpoint
        )
        let client = MockSessionStoreClient(
            projects: [activeProject, browsedProject],
            sessions: [],
            workspaceSessions: [
                activeProject.id: [activeSession],
                browsedProject.id: [browsedSession]
            ],
            messagesResult: []
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: recentStore,
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.selectProject(activeProject)
        await store.selectSession(activeSession)
        store.takeOverSession(activeSession)
        XCTAssertEqual(sockets.count, 1)
        let socketCount = sockets.count
        let disconnectCallCount = sockets.first?.disconnectCallCount

        try await store.refreshWorkspaceSessions(projectID: browsedProject.id)

        XCTAssertEqual(store.sessions(forProjectID: browsedProject.id).map(\.id), [browsedSession.id])
        XCTAssertEqual(store.selectedProjectID, activeProject.id)
        XCTAssertEqual(store.selectedSessionID, activeSession.id)
        XCTAssertEqual(sockets.count, socketCount)
        XCTAssertEqual(sockets.first?.disconnectCallCount, disconnectCallCount)
        XCTAssertEqual(client.requestedWorkspaceIDs, [activeProject.id, browsedProject.id])
    }

    func testWorkspaceCatalogKeepsOnlyExplicitlyOpenedDirectories() async throws {
        let openedProject = makeProject(id: "opened-project")
        let legacyAutoProject = makeProject(id: "legacy-auto-project")
        let unopenedCandidate = makeProject(id: "unopened-candidate")
        let openedWorkspace = AgentWorkspace(
            project: openedProject,
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        // 旧版目录刷新会把 projects() 候选项直接写入 recent，特征是没有明确打开时间。
        let legacyAutoWorkspace = AgentWorkspace(project: legacyAutoProject)
        let appStore = AppStore()
        let recentStore = makeRecentWorkspaceStore(
            workspaces: [openedWorkspace, legacyAutoWorkspace],
            endpoint: appStore.endpoint
        )
        let client = MockSessionStoreClient(
            projects: [openedProject, legacyAutoProject, unopenedCandidate],
            sessions: []
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: recentStore,
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        XCTAssertEqual(Set(store.sidebarProjects.map(\.id)), [openedProject.id, legacyAutoProject.id])

        try await store.refreshWorkspaceCatalog()

        XCTAssertEqual(store.projects.map(\.id), [openedProject.id, legacyAutoProject.id, unopenedCandidate.id])
        XCTAssertEqual(store.sidebarProjects.map(\.id), [openedProject.id])
        XCTAssertEqual(recentStore.load(endpoint: appStore.endpoint).map(\.id), [openedProject.id])
    }

    func testApprovalSummaryDecodesLegacyPayloadAndRequiresDetailsForApproval() throws {
        let legacyJSON = #"{"id":"approval-legacy","title":"运行命令","kind":"command","count":1}"#
        let legacy = try JSONDecoder().decode(ApprovalSummary.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(legacy.body)
        XCTAssertNil(legacy.risk)
        XCTAssertFalse(legacy.hasDecisionContext)

        let explicit = ApprovalSummary(
            id: "approval-explicit",
            title: "运行 go test ./...",
            body: "go test ./...",
            kind: "command",
            risk: "会执行测试命令",
            count: 1
        )
        XCTAssertTrue(explicit.hasDecisionContext)
    }

    func testEventReducerRetainsApprovalBodyAndRisk() async throws {
        let reducer = EventReducer()
        let output = await reducer.reduce(
            .approvalRequest(
                AgentApprovalRequest(
                    id: "approval-detail",
                    title: "运行 go test ./...",
                    body: "go test ./...",
                    kind: "command",
                    risk: "将在当前工作区执行"
                ),
                AgentEventMetadata(
                    seq: 1,
                    sessionID: "sess-approval-detail",
                    turnID: "turn-1",
                    itemID: "item-1",
                    messageID: nil,
                    clientMessageID: nil,
                    revision: nil,
                    createdAt: nil
                )
            ),
            fallbackSessionID: "fallback",
            outputIdleClearDelay: 0
        )

        let approval = try XCTUnwrap(output.pendingApprovalUpdates.first?.1)
        XCTAssertEqual(approval.body, "go test ./...")
        XCTAssertEqual(approval.risk, "将在当前工作区执行")
    }

    func testSessionStoreSearchFiltersLoadedSessionsAndProjects() async {
        let firstProject = makeProject(id: "proj_alpha")
        let secondProject = makeProject(id: "proj_beta")
        let metadataReview = makeSession(
            id: "codex_review",
            projectID: firstProject.id,
            title: "审核元数据修复",
            status: "history",
            source: "codex",
            resumeID: "review",
            preview: "替换 App Store 高风险描述",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let featureAudit = makeSession(
            id: "codex_feature_audit",
            projectID: secondProject.id,
            title: "功能对齐检查",
            status: "history",
            source: "codex",
            resumeID: "feature",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let client = MockSessionStoreClient(
            projects: [firstProject, secondProject],
            sessions: [],
            projectSessions: [
                firstProject.id: [metadataReview],
                secondProject.id: [featureAudit]
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.selectProject(firstProject)
        await store.selectProject(secondProject)

        store.selectedProjectID = firstProject.id
        store.sessionSearchQuery = "App Store"
        XCTAssertEqual(store.filteredSessions.map(\.id), [metadataReview.id])
        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [metadataReview.id])
        XCTAssertEqual(store.filteredSidebarProjects.map(\.id), [firstProject.id])
        XCTAssertEqual(store.sessionListSnapshot(forProjectID: firstProject.id).visibleSessions.map(\.id), [metadataReview.id])

        store.sessionSearchQuery = "proj_beta"
        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [featureAudit.id])
        XCTAssertEqual(store.filteredSidebarProjects.map(\.id), [secondProject.id])

        store.sessionSearchQuery = ""
        XCTAssertEqual(store.filteredSessions.map(\.id), [metadataReview.id])
        // 全局会话库和“最近”不受当前工作区筛选影响，并严格按最后活动时间排序。
        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [featureAudit.id, metadataReview.id])
        XCTAssertEqual(store.recentSessions.map(\.id), [featureAudit.id, metadataReview.id])
        XCTAssertEqual(Set(store.filteredSidebarProjects.map(\.id)), Set([firstProject.id, secondProject.id]))
    }

    func testThreadSearchDebouncesLatestQueryAndKeepsLocalSessionsWhenCleared() async throws {
        let project = makeProject(id: "proj_thread_search_debounce")
        let local = makeSession(
            id: "local_thread_search",
            projectID: project.id,
            title: "本地已加载会话",
            status: "history",
            source: "codex"
        )
        let remote = makeSession(
            id: "remote_thread_search",
            projectID: project.id,
            title: "远端正文命中",
            status: "history",
            source: "codex",
            preview: "needle 位于更早的消息正文"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectSessions: [project.id: [local]],
            threadSearchHandler: { query, _, _ in
                ThreadSearchPage(results: [ThreadSearchResult(session: remote, snippet: "\(query) 位于更早的消息正文")])
            }
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionSearchDebounceNanoseconds: 50_000_000
        )
        await store.selectProject(project)
        store.selectedSessionID = local.id

        store.sessionSearchQuery = "旧关键词"
        try await Task.sleep(nanoseconds: 5_000_000)
        store.sessionSearchQuery = "needle"
        for _ in 0..<100 where client.requestedThreadSearchQueries.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(client.requestedThreadSearchQueries, ["needle"], "防抖窗口内只应发送最后一个查询")
        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [remote.id])
        XCTAssertEqual(store.selectedSessionID, local.id, "搜索结果合并不能改写当前选择")

        store.sessionSearchQuery = ""
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(client.requestedThreadSearchQueries, ["needle"], "空查询不能发 thread/search")
        XCTAssertEqual(store.sessions.map(\.id), [local.id], "清空搜索不能删除已加载会话")
        XCTAssertTrue(store.remoteSessionSearchResults.isEmpty)
        XCTAssertEqual(store.selectedSessionID, local.id)
    }

    func testThreadSearchIgnoresCanceledLateResponse() async throws {
        let project = makeProject(id: "proj_thread_search_stale")
        let first = makeSession(
            id: "remote_first_stale",
            projectID: project.id,
            title: "first",
            status: "history",
            source: "codex",
            preview: "first"
        )
        let second = makeSession(
            id: "remote_second_current",
            projectID: project.id,
            title: "second",
            status: "history",
            source: "codex",
            preview: "second"
        )
        let gate = ThreadSearchResponseGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            threadSearchHandler: { query, _, _ in
                try await gate.search(query: query)
            }
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionSearchDebounceNanoseconds: 0
        )

        store.sessionSearchQuery = "first"
        try await waitForThreadSearchQueries(gate, count: 1)
        store.sessionSearchQuery = "second"
        try await waitForThreadSearchQueries(gate, count: 2)

        gate.resolve(
            query: "second",
            page: ThreadSearchPage(results: [ThreadSearchResult(session: second, snippet: "second")])
        )
        for _ in 0..<100 where store.remoteSessionSearchResults.map(\.id) != [second.id] {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        gate.resolve(
            query: "first",
            page: ThreadSearchPage(results: [ThreadSearchResult(session: first, snippet: "first")])
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.remoteSessionSearchResults.map(\.id), [second.id])
        XCTAssertFalse(store.sessions.contains(where: { $0.id == first.id }), "已取消查询的迟到响应不能污染基础缓存")
    }

    func testThreadSearchUnavailableSilentlyFallsBackToLocalResults() async throws {
        let project = makeProject(id: "proj_thread_search_fallback")
        let local = makeSession(
            id: "local_thread_search_fallback",
            projectID: project.id,
            title: "旧服务也能本地搜索",
            status: "history",
            source: "codex",
            preview: "fallback needle"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectSessions: [project.id: [local]],
            threadSearchHandler: { _, _, _ in
                throw CodexAppServerSessionRuntimeError.threadSearchUnavailable
            }
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionSearchDebounceNanoseconds: 0
        )
        await store.selectProject(project)
        let statusBeforeSearch = store.statusMessage

        store.sessionSearchQuery = "fallback needle"
        for _ in 0..<100 where client.requestedThreadSearchQueries.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(store.filteredSessions.map(\.id), [local.id])
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.statusMessage, statusBeforeSearch, "搜索失败不能改写全局状态提示")
        XCTAssertNil(store.connectionTermination)
        XCTAssertTrue(store.remoteSessionSearchResults.isEmpty)
    }

    func testThreadSearchInitialLoadingCoversDebounceAndFinishesOnSuccessAndFailure() async throws {
        let project = makeProject(id: "proj_thread_search_initial_loading")
        let local = makeSession(
            id: "thread_search_initial_loading_local",
            projectID: project.id,
            title: "本地 local 命中",
            status: "history",
            source: "codex"
        )
        let remote = makeSession(
            id: "thread_search_initial_loading_remote",
            projectID: project.id,
            title: "远端正文命中",
            status: "history",
            source: "codex"
        )
        let gate = ThreadSearchResponseGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectSessions: [project.id: [local]],
            threadSearchHandler: { query, cursor, _ in
                try await gate.search(query: query, cursor: cursor)
            }
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionSearchDebounceNanoseconds: 50_000_000
        )
        await store.selectProject(project)
        let statusBeforeSearch = store.statusMessage

        store.sessionSearchQuery = "local"
        XCTAssertTrue(store.isSearchingRemoteSessionResults, "首屏 loading 必须从防抖阶段开始")
        XCTAssertTrue(gate.requests.isEmpty, "防抖未结束前不应提前发请求")
        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [local.id], "已有本地命中不能被首屏 loading 覆盖")
        try await waitForThreadSearchQueries(gate, count: 1)
        XCTAssertTrue(store.isSearchingRemoteSessionResults)

        gate.resolve(
            query: "local",
            page: ThreadSearchPage(results: [ThreadSearchResult(session: remote, snippet: "local 正文命中")])
        )
        for _ in 0..<100 where store.isSearchingRemoteSessionResults {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.isSearchingRemoteSessionResults)
        XCTAssertEqual(Set(store.sessionLibrarySessions.map(\.id)), Set([local.id, remote.id]))

        store.sessionSearchQuery = "failure"
        XCTAssertTrue(store.isSearchingRemoteSessionResults)
        try await waitForThreadSearchQueries(gate, count: 2)
        gate.fail(query: "failure", error: URLError(.timedOut))
        for _ in 0..<100 where store.isSearchingRemoteSessionResults {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(store.isSearchingRemoteSessionResults)
        XCTAssertFalse(store.isLoadingMoreSessionSearchResults)
        XCTAssertTrue(store.remoteSessionSearchResults.isEmpty, "首屏失败只静默回退本地过滤")
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.statusMessage, statusBeforeSearch)
        XCTAssertNil(store.connectionTermination)
    }

    func testThreadSearchInitialLoadingIgnoresOldQueryAndResetsAfterMacSwitch() async throws {
        let suiteName = "ConversationDataFlowTests.ThreadSearchInitialLoadingConnection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://100.64.0.10:8787", forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations(itemData: Data("old-token".utf8))
        let appStore = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        let project = makeProject(id: "proj_thread_search_initial_loading_stale")
        let oldResult = makeSession(
            id: "thread_search_initial_loading_old",
            projectID: project.id,
            title: "旧查询结果",
            status: "history",
            source: "codex"
        )
        let currentResult = makeSession(
            id: "thread_search_initial_loading_current",
            projectID: project.id,
            title: "旧 Mac 结果",
            status: "history",
            source: "codex"
        )
        let gate = ThreadSearchResponseGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            threadSearchHandler: { query, cursor, _ in
                try await gate.search(query: query, cursor: cursor)
            }
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionSearchDebounceNanoseconds: 0
        )

        store.sessionSearchQuery = "old"
        try await waitForThreadSearchQueries(gate, count: 1)
        XCTAssertTrue(store.isSearchingRemoteSessionResults)

        store.sessionSearchQuery = "current"
        try await waitForThreadSearchQueries(gate, count: 2)
        XCTAssertTrue(store.isSearchingRemoteSessionResults)
        gate.resolve(
            query: "old",
            page: ThreadSearchPage(results: [ThreadSearchResult(session: oldResult, snippet: "不得落地")])
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(store.isSearchingRemoteSessionResults, "旧 query 的迟到 defer 不能清掉新 query 的 loading")
        XCTAssertTrue(store.remoteSessionSearchResults.isEmpty)

        let oldConnectionGeneration = appStore.connectionGeneration
        XCTAssertTrue(try store.commitPreparedConnection(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "new-token"
        )))
        XCTAssertGreaterThan(appStore.connectionGeneration, oldConnectionGeneration)
        XCTAssertEqual(store.sessionSearchQuery, "")
        XCTAssertFalse(store.isSearchingRemoteSessionResults)
        XCTAssertFalse(store.isLoadingMoreSessionSearchResults)
        XCTAssertTrue(store.remoteSessionSearchResults.isEmpty)

        gate.resolve(
            query: "current",
            page: ThreadSearchPage(results: [ThreadSearchResult(session: currentResult, snippet: "旧 Mac 不得回填")])
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(store.isSearchingRemoteSessionResults)
        XCTAssertTrue(store.remoteSessionSearchResults.isEmpty, "旧 Mac 的迟到响应不能恢复结果或 loading")
    }

    func testThreadSearchPaginationMergesByIDUpdatesSnippetAndStopsOnSameCursor() async throws {
        let project = makeProject(id: "proj_thread_search_page_merge")
        let canonical = makeSession(
            id: "thread_page_duplicate",
            projectID: project.id,
            title: "本地权威标题",
            status: "history",
            source: "codex",
            preview: "本地 preview 不能被搜索覆盖"
        )
        let remoteFirst = makeSession(
            id: canonical.id,
            projectID: project.id,
            title: "远端首屏标题",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 3)
        )
        let remoteUpdated = makeSession(
            id: canonical.id,
            projectID: project.id,
            title: "远端分页更新标题",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 4)
        )
        let remoteSecond = makeSession(
            id: "thread_page_second",
            projectID: project.id,
            title: "分页新增",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectSessions: [project.id: [canonical]],
            threadSearchHandler: { _, cursor, _ in
                switch cursor {
                case nil:
                    return ThreadSearchPage(
                        results: [ThreadSearchResult(session: remoteFirst, snippet: "首屏 snippet")],
                        nextCursor: "cursor-1"
                    )
                case "cursor-1":
                    return ThreadSearchPage(
                        results: [
                            ThreadSearchResult(session: remoteUpdated, snippet: "分页更新 snippet"),
                            ThreadSearchResult(session: remoteSecond, snippet: "分页新增 snippet")
                        ],
                        nextCursor: "cursor-1"
                    )
                default:
                    throw MockError.unimplemented
                }
            }
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionSearchDebounceNanoseconds: 0
        )
        await store.selectProject(project)

        store.sessionSearchQuery = "needle"
        for _ in 0..<100 where store.sessionSearchNextCursor != "cursor-1" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await store.loadMoreSessionSearchResults()

        XCTAssertEqual(Set(store.remoteSessionSearchResults.map(\.id)), Set([canonical.id, remoteSecond.id]))
        XCTAssertEqual(store.remoteSessionSearchResults.first(where: { $0.id == canonical.id })?.title, remoteUpdated.title)
        XCTAssertEqual(store.sessionSearchSnippet(for: canonical.id), "分页更新 snippet")
        XCTAssertEqual(store.sessions.first(where: { $0.id == canonical.id })?.title, canonical.title)
        XCTAssertEqual(store.sessions.first(where: { $0.id == canonical.id })?.preview, canonical.preview)
        XCTAssertNil(store.sessionSearchNextCursor, "服务端返回本次请求 cursor 时必须终止，避免死循环")
        XCTAssertFalse(store.sessionSearchHasMore)

        await store.loadMoreSessionSearchResults()
        XCTAssertEqual(client.requestedThreadSearchCursors, [nil, "cursor-1"], "终止后再次点击不能继续发请求")
    }

    func testThreadSearchPaginationDeduplicatesClicksAndRetainsCursorForRetry() async throws {
        let project = makeProject(id: "proj_thread_search_page_retry")
        let first = makeSession(
            id: "thread_page_retry_first",
            projectID: project.id,
            title: "首屏结果",
            status: "history",
            source: "codex"
        )
        let second = makeSession(
            id: "thread_page_retry_second",
            projectID: project.id,
            title: "重试结果",
            status: "history",
            source: "codex"
        )
        let gate = ThreadSearchResponseGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            threadSearchHandler: { query, cursor, _ in
                if cursor == nil {
                    return ThreadSearchPage(
                        results: [ThreadSearchResult(session: first, snippet: "首屏")],
                        nextCursor: "retry-cursor"
                    )
                }
                return try await gate.search(query: query, cursor: cursor)
            }
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionSearchDebounceNanoseconds: 0
        )

        store.sessionSearchQuery = "retry"
        for _ in 0..<100 where store.sessionSearchNextCursor != "retry-cursor" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let statusBeforePage = store.statusMessage
        let firstPageTask = Task { @MainActor in
            await store.loadMoreSessionSearchResults()
        }
        try await waitForThreadSearchQueries(gate, count: 1)

        await store.loadMoreSessionSearchResults()
        XCTAssertEqual(gate.requests.count, 1, "分页在途时重复点击只能保留一个请求")
        XCTAssertTrue(store.isLoadingMoreSessionSearchResults)

        gate.fail(query: "retry", cursor: "retry-cursor", error: URLError(.timedOut))
        await firstPageTask.value
        XCTAssertEqual(store.remoteSessionSearchResults.map(\.id), [first.id])
        XCTAssertEqual(store.sessionSearchNextCursor, "retry-cursor")
        XCTAssertTrue(store.sessionSearchHasMore)
        XCTAssertFalse(store.isLoadingMoreSessionSearchResults)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.statusMessage, statusBeforePage)
        XCTAssertNil(store.connectionTermination)

        let retryTask = Task { @MainActor in
            await store.loadMoreSessionSearchResults()
        }
        try await waitForThreadSearchQueries(gate, count: 2)
        gate.resolve(
            query: "retry",
            cursor: "retry-cursor",
            page: ThreadSearchPage(
                results: [ThreadSearchResult(session: second, snippet: "重试成功")]
            )
        )
        await retryTask.value

        XCTAssertEqual(Set(store.remoteSessionSearchResults.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(gate.requests.count, 2, "失败后应允许使用同一 cursor 显式重试")
        XCTAssertFalse(store.sessionSearchHasMore)
    }

    func testThreadSearchPaginationDropsLatePagesAfterNewQueryAndConnectionChange() async throws {
        let suiteName = "ConversationDataFlowTests.ThreadSearchPaginationConnection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://100.64.0.10:8787", forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations(itemData: Data("old-token".utf8))
        let appStore = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        let project = makeProject(id: "proj_thread_search_page_stale")
        let oldFirst = makeSession(
            id: "thread_page_old_first",
            projectID: project.id,
            title: "旧查询首屏",
            status: "history",
            source: "codex"
        )
        let oldLate = makeSession(
            id: "thread_page_old_late",
            projectID: project.id,
            title: "旧查询迟到页",
            status: "history",
            source: "codex"
        )
        let currentFirst = makeSession(
            id: "thread_page_current_first",
            projectID: project.id,
            title: "新查询首屏",
            status: "history",
            source: "codex"
        )
        let currentLate = makeSession(
            id: "thread_page_current_late",
            projectID: project.id,
            title: "旧 Mac 迟到页",
            status: "history",
            source: "codex"
        )
        let gate = ThreadSearchResponseGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            threadSearchHandler: { query, cursor, _ in
                switch (query, cursor) {
                case ("old", nil):
                    return ThreadSearchPage(
                        results: [ThreadSearchResult(session: oldFirst, snippet: "旧首屏")],
                        nextCursor: "old-cursor"
                    )
                case ("current", nil):
                    return ThreadSearchPage(
                        results: [ThreadSearchResult(session: currentFirst, snippet: "新首屏")],
                        nextCursor: "current-cursor"
                    )
                default:
                    return try await gate.search(query: query, cursor: cursor)
                }
            }
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionSearchDebounceNanoseconds: 0
        )

        store.sessionSearchQuery = "old"
        for _ in 0..<100 where store.sessionSearchNextCursor != "old-cursor" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let oldPageTask = Task { @MainActor in
            await store.loadMoreSessionSearchResults()
        }
        try await waitForThreadSearchQueries(gate, count: 1)

        store.sessionSearchQuery = "current"
        for _ in 0..<100 where store.sessionSearchNextCursor != "current-cursor" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        gate.resolve(
            query: "old",
            cursor: "old-cursor",
            page: ThreadSearchPage(
                results: [ThreadSearchResult(session: oldLate, snippet: "不得落地")],
                nextCursor: "old-next"
            )
        )
        await oldPageTask.value
        XCTAssertEqual(store.remoteSessionSearchResults.map(\.id), [currentFirst.id])
        XCTAssertEqual(store.sessionSearchNextCursor, "current-cursor")
        XCTAssertFalse(store.isLoadingMoreSessionSearchResults)

        let currentPageTask = Task { @MainActor in
            await store.loadMoreSessionSearchResults()
        }
        try await waitForThreadSearchQueries(gate, count: 2)
        let oldConnectionGeneration = appStore.connectionGeneration
        XCTAssertTrue(try store.commitPreparedConnection(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "new-token"
        )))
        XCTAssertGreaterThan(appStore.connectionGeneration, oldConnectionGeneration)
        XCTAssertEqual(store.sessionSearchQuery, "", "切换 Mac 后不能保留旧 Mac 的搜索词")
        XCTAssertTrue(store.remoteSessionSearchResults.isEmpty)
        XCTAssertNil(store.sessionSearchNextCursor)
        XCTAssertFalse(store.sessionSearchHasMore)
        XCTAssertFalse(store.isLoadingMoreSessionSearchResults)

        gate.resolve(
            query: "current",
            cursor: "current-cursor",
            page: ThreadSearchPage(
                results: [ThreadSearchResult(session: currentLate, snippet: "旧 Mac 不得回填")],
                nextCursor: "current-next"
            )
        )
        await currentPageTask.value
        XCTAssertTrue(store.remoteSessionSearchResults.isEmpty)
        XCTAssertNil(store.sessionSearchNextCursor)
        XCTAssertFalse(store.isLoadingMoreSessionSearchResults)
    }

    func testSessionStoreRefreshesGitStatusForSelectedSessionPath() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git", projectID: project.id, title: "检查 Git", status: "history", source: "codex", resumeID: "git")
        let gitStatus = GitStatusResponse(
            path: session.dir,
            isRepository: true,
            branch: "main",
            head: "abc123",
            statusText: " M README.md",
            diffStat: " README.md | 2 +-",
            unstagedDiff: "@@ -1 +1 @@\n-before\n+after",
            stagedDiff: nil,
            truncated: false,
            truncatedNote: nil
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitStatusResults: [session.dir: .success(gitStatus)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.refreshSelectedGitStatus()

        XCTAssertEqual(client.requestedGitStatusPaths, [session.dir])
        XCTAssertEqual(store.selectedGitStatus?.unstagedDiff, gitStatus.unstagedDiff)
        XCTAssertNil(store.selectedGitStatusErrorMessage)
    }

    func testSessionStorePerformsGitActionAndUpdatesCachedStatus() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_action", projectID: project.id, title: "暂存 Git", status: "history", source: "codex", resumeID: "git-action")
        let updatedStatus = GitStatusResponse(
            path: session.dir,
            isRepository: true,
            branch: "main",
            head: "abc123",
            statusText: "M  README.md",
            diffStat: nil,
            unstagedDiff: nil,
            stagedDiff: "@@ -1 +1 @@\n-before\n+after",
            files: [
                GitFileStatus(path: "README.md", code: "M ", staged: true, unstaged: false, untracked: false)
            ],
            truncated: false,
            truncatedNote: nil
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitActionResults: [session.dir: .success(updatedStatus)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.performSelectedGitAction(.stage, files: ["README.md"])

        XCTAssertEqual(client.requestedGitActions, [
            RequestedGitAction(path: session.dir, action: .stage, files: ["README.md"])
        ])
        XCTAssertEqual(store.selectedGitStatus?.stagedDiff, updatedStatus.stagedDiff)
        XCTAssertEqual(store.selectedGitStatus?.files.first?.path, "README.md")
        XCTAssertNil(store.selectedGitActionErrorMessage)
    }

    func testSessionStorePerformsGitPatchActionAndUpdatesCachedStatus() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_patch_action", projectID: project.id, title: "暂存 hunk", status: "history", source: "codex", resumeID: "git-patch-action")
        let patch = "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-before\n+after\n"
        let updatedStatus = GitStatusResponse(
            path: session.dir,
            isRepository: true,
            branch: "main",
            head: "abc123",
            statusText: "M  README.md",
            diffStat: nil,
            unstagedDiff: nil,
            stagedDiff: patch,
            files: [
                GitFileStatus(path: "README.md", code: "M ", staged: true, unstaged: false, untracked: false)
            ],
            truncated: false,
            truncatedNote: nil
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitPatchActionResults: [session.dir: .success(updatedStatus)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.performSelectedGitPatchAction(.stagePatch, patch: patch)

        XCTAssertEqual(client.requestedGitPatchActions, [
            RequestedGitPatchAction(path: session.dir, action: .stagePatch, patch: patch.trimmingCharacters(in: .whitespacesAndNewlines))
        ])
        XCTAssertEqual(store.selectedGitStatus?.stagedDiff, updatedStatus.stagedDiff)
        XCTAssertNil(store.selectedGitActionErrorMessage)
    }

    func testSessionStoreCommitsGitChangesAndUpdatesCachedStatus() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_commit", projectID: project.id, title: "提交 Git", status: "history", source: "codex", resumeID: "git-commit")
        let cleanStatus = GitStatusResponse(
            path: session.dir,
            isRepository: true,
            branch: "main",
            head: "def456",
            statusText: nil,
            diffStat: nil,
            unstagedDiff: nil,
            stagedDiff: nil,
            files: [],
            truncated: false,
            truncatedNote: nil
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitCommitResults: [session.dir: .success(cleanStatus)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.commitSelectedGitChanges(message: " update readme ")

        XCTAssertEqual(client.requestedGitCommits, [
            RequestedGitCommit(path: session.dir, message: "update readme")
        ])
        XCTAssertEqual(store.selectedGitStatus?.head, "def456")
        XCTAssertEqual(store.selectedGitStatus?.hasChanges, false)
        XCTAssertNil(store.selectedGitActionErrorMessage)
    }

    func testSessionStorePushesGitBranchAndUpdatesStatus() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_push", projectID: project.id, title: "Push Git", status: "history", source: "codex", resumeID: "git-push")
        let status = GitStatusResponse(
            path: session.dir,
            isRepository: true,
            branch: "mimi/feature",
            head: "fed456",
            statusText: nil,
            diffStat: nil,
            unstagedDiff: nil,
            stagedDiff: nil,
            files: [],
            truncated: false,
            truncatedNote: nil
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitPushResults: [
                session.dir: .success(GitPushResponse(path: session.dir, remote: "origin", branch: "mimi/feature", output: "pushed", status: status))
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.pushSelectedGitBranch(remote: " origin ")

        XCTAssertEqual(client.requestedGitPushes, [
            RequestedGitPush(path: session.dir, remote: "origin")
        ])
        XCTAssertEqual(store.selectedGitStatus?.head, "fed456")
        XCTAssertNil(store.selectedGitActionErrorMessage)
    }

    func testSessionStoreCreatesDraftPullRequestAndStoresURL() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_pr", projectID: project.id, title: "PR Git", status: "history", source: "codex", resumeID: "git-pr")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitPullRequestResults: [
                session.dir: .success(GitPullRequestResponse(
                    path: session.dir,
                    branch: "mimi/feature",
                    url: "https://github.com/example/repo/pull/1",
                    output: "https://github.com/example/repo/pull/1"
                ))
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.createSelectedPullRequest(title: " Draft PR ", body: "Summary", draft: true)

        XCTAssertEqual(client.requestedGitPullRequests, [
            RequestedGitPullRequest(path: session.dir, title: "Draft PR", body: "Summary", draft: true)
        ])
        XCTAssertEqual(store.selectedPullRequestURL, "https://github.com/example/repo/pull/1")
        XCTAssertEqual(store.selectedPullRequestStatus?.branch, "mimi/feature")
        XCTAssertEqual(store.selectedPullRequestStatus?.title, "Draft PR")
        XCTAssertEqual(store.selectedPullRequestStatus?.isDraft, true)
        XCTAssertNil(store.selectedGitActionErrorMessage)
    }

    func testSessionStoreRefreshesPullRequestStatus() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_git_pr_status", projectID: project.id, title: "PR 状态", status: "history", source: "codex", resumeID: "git-pr-status")
        let status = GitPullRequestStatusResponse(
            path: session.dir,
            branch: "mimi/feature",
            exists: true,
            number: 42,
            title: "Review changes",
            state: "OPEN",
            url: "https://github.com/example/repo/pull/42",
            isDraft: false,
            reviewDecision: "REVIEW_REQUIRED",
            mergeStateStatus: "CLEAN",
            headRefName: "mimi/feature",
            baseRefName: "main"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            gitPullRequestStatusResults: [session.dir: .success(status)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.refreshSelectedPullRequestStatus()

        XCTAssertEqual(client.requestedGitPullRequestStatusPaths, [session.dir])
        XCTAssertEqual(store.selectedPullRequestStatus, status)
        XCTAssertEqual(store.selectedPullRequestURL, status.url)
        XCTAssertNil(store.selectedPullRequestStatusErrorMessage)
    }

    func testCommandActionDecodesConfirmationFlagWithSafeDefault() throws {
        let json = """
        {
          "path": "/Users/me/code/app",
          "actions": [
            {
              "id": "go-test",
              "name": "Go Test",
              "command": "go",
              "args": ["test", "./..."],
              "working_dir": "/Users/me/code/app",
              "timeout_seconds": 60
            },
            {
              "id": "clean-cache",
              "name": "Clean Cache",
              "command": "go",
              "args": ["clean", "-cache"],
              "working_dir": "/Users/me/code/app",
              "timeout_seconds": 30,
              "requires_confirmation": true
            }
          ]
        }
        """

        let response = try AgentAPIClient.decoder.decode(CommandActionListResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.actions.map(\.id), ["go-test", "clean-cache"])
        XCTAssertFalse(response.actions[0].requiresConfirmation)
        XCTAssertTrue(response.actions[1].requiresConfirmation)
    }

    func testSessionStoreLoadsAndRunsCommandActions() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_action", projectID: project.id, title: "运行动作", status: "history", source: "codex", resumeID: "action")
        let action = AgentCommandAction(
            id: "go-test",
            name: "Go Test",
            command: "go",
            args: ["test", "./..."],
            workingDir: session.dir,
            timeoutSeconds: 20,
            requiresConfirmation: true
        )
        let result = CommandActionRunResponse(
            id: action.id,
            name: action.name,
            path: session.dir,
            workingDir: session.dir,
            command: action.command,
            args: action.args,
            success: true,
            exitCode: 0,
            output: "ok",
            truncated: false,
            timedOut: false,
            durationMS: 42
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            commandActionResults: [session.dir: .success([action])],
            commandActionRunResults: ["\(session.dir)#\(action.id)": .success(result)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.refreshSelectedCommandActions()
        await store.runSelectedCommandAction(action)

        XCTAssertEqual(client.requestedCommandActionPaths, [session.dir])
        XCTAssertEqual(client.requestedCommandActionRuns, [RequestedCommandActionRun(path: session.dir, id: action.id, confirmed: true)])
        XCTAssertEqual(store.selectedCommandActions, [action])
        XCTAssertEqual(store.selectedCommandActionResult, result)
        XCTAssertEqual(store.selectedCommandActionHistory, [result])
        XCTAssertNil(store.selectedCommandActionErrorMessage)
    }

    func testSessionStoreQueuesCommandActionsFIFO() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_action_queue", projectID: project.id, title: "动作队列", status: "history", source: "codex", resumeID: "action-queue")
        let firstAction = AgentCommandAction(
            id: "lint",
            name: "Lint",
            command: "npm",
            args: ["run", "lint"],
            workingDir: session.dir,
            timeoutSeconds: 30
        )
        let secondAction = AgentCommandAction(
            id: "test",
            name: "Test",
            command: "go",
            args: ["test", "./..."],
            workingDir: session.dir,
            timeoutSeconds: 60
        )
        let firstResult = CommandActionRunResponse(
            id: firstAction.id,
            name: firstAction.name,
            path: session.dir,
            workingDir: session.dir,
            command: firstAction.command,
            args: firstAction.args,
            success: true,
            exitCode: 0,
            output: "lint ok",
            truncated: false,
            timedOut: false,
            durationMS: 20
        )
        let secondResult = CommandActionRunResponse(
            id: secondAction.id,
            name: secondAction.name,
            path: session.dir,
            workingDir: session.dir,
            command: secondAction.command,
            args: secondAction.args,
            success: true,
            exitCode: 0,
            output: "test ok",
            truncated: false,
            timedOut: false,
            durationMS: 40
        )
        let client = DelayedCommandActionClient(
            projects: [project],
            sessions: [session],
            actionsByPath: [session.dir: [firstAction, secondAction]],
            runResults: [
                "\(session.dir)#\(firstAction.id)": .success(firstResult),
                "\(session.dir)#\(secondAction.id)": .success(secondResult)
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.refreshSelectedCommandActions()

        let runningTask = Task { await store.runSelectedCommandAction(firstAction) }
        await client.waitForRunRequestCount(1)

        XCTAssertEqual(store.runningCommandActionPath, session.dir)
        XCTAssertEqual(store.runningCommandActionID, firstAction.id)
        XCTAssertEqual(store.selectedQueuedCommandActionIDs, [])

        await store.runSelectedCommandAction(secondAction)

        XCTAssertEqual(client.requestedCommandActionRuns, [RequestedCommandActionRun(path: session.dir, id: firstAction.id, confirmed: false)])
        XCTAssertEqual(store.selectedQueuedCommandActionIDs, [secondAction.id])

        client.resolveRun(at: 0)
        await client.waitForRunRequestCount(2)

        XCTAssertEqual(store.runningCommandActionPath, session.dir)
        XCTAssertEqual(store.runningCommandActionID, secondAction.id)
        XCTAssertEqual(store.selectedQueuedCommandActionIDs, [])

        client.resolveRun(at: 1)
        await runningTask.value

        XCTAssertNil(store.runningCommandActionPath)
        XCTAssertNil(store.runningCommandActionID)
        XCTAssertEqual(
            client.requestedCommandActionRuns,
            [
                RequestedCommandActionRun(path: session.dir, id: firstAction.id, confirmed: false),
                RequestedCommandActionRun(path: session.dir, id: secondAction.id, confirmed: false)
            ]
        )
        XCTAssertEqual(store.selectedCommandActionHistory, [secondResult, firstResult])
        XCTAssertNil(store.selectedCommandActionErrorMessage)
    }

    func testSessionStoreRefreshesCapabilitiesForSelectedPath() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_caps", projectID: project.id, title: "能力", status: "history", source: "codex", resumeID: "caps")
        let response = CapabilityListResponse(
            path: session.dir,
            skills: [
                SkillCapability(name: "review", description: "Review changes", scope: "repo", path: "\(session.dir)/.agents/skills/review/SKILL.md", enabled: true)
            ],
            mcpServers: [
                MCPCapability(name: "context7", scope: "user", configPath: "/Users/me/.codex/config.toml", transport: "stdio", command: "npx", url: nil, enabled: true, plugin: nil)
            ]
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            capabilityResults: [session.dir: .success(response)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        await store.refreshCapabilities()

        XCTAssertEqual(client.requestedCapabilityPaths, [session.dir])
        XCTAssertEqual(store.capabilityList, response)
        XCTAssertNil(store.capabilityErrorMessage)
    }

}
