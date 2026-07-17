import XCTest
import Combine
import Security
import SwiftUI
import UIKit
@testable import MimiRemote

@MainActor
final class ConversationDataFlowTests: XCTestCase {
    func testConnectionCommitFailureKeepsPreviousConnectionAndSessionState() async throws {
        let suiteName = "ConversationDataFlowTests.ConnectionCommitFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let oldEndpoint = "http://100.64.0.10:8787"
        let oldToken = "old-token"
        defaults.set(oldEndpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations(itemData: Data(oldToken.utf8))
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain)
        )
        let project = makeProject(id: "proj_connection_commit_failure")
        let running = makeSession(
            id: "sess_connection_commit_failure",
            projectID: project.id,
            title: "保留中的会话",
            status: "running",
            source: "codex"
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
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
        store.takeOverSession(running)
        await store.selectSession(running)
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        let oldGeneration = appStore.connectionGeneration

        // 模拟系统 Keychain 暂时不可写。提交失败后不能先拆旧 WebSocket，也不能清空会话列表。
        keychain.forcedUpdateStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(
            try store.commitPreparedConnection(
                PreparedConnectionSettings(
                    endpoint: "http://100.64.0.20:8787",
                    token: "new-token"
                )
            )
        )

        XCTAssertEqual(appStore.endpoint, oldEndpoint)
        XCTAssertEqual(appStore.token, oldToken)
        XCTAssertEqual(appStore.connectionGeneration, oldGeneration)
        XCTAssertEqual(defaults.string(forKey: "agentd.endpoint"), oldEndpoint)
        XCTAssertEqual(keychain.itemData, Data(oldToken.utf8))
        XCTAssertEqual(socket.disconnectCallCount, 0)
        XCTAssertEqual(socket.connectedSessionIDs, [running.id])
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(store.webSocketStatus, .connected)
        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertEqual(store.sessions.map(\.id), [running.id])
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertEqual(store.selectedSessionID, running.id)
    }

    func testConnectionProfileSwitchCommitsBeforeRetiringOldWebSocket() async throws {
        let suiteName = "ConversationDataFlowTests.ProfileSwitchSuccess.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = [
            ConnectionProfile(id: "mac-a", displayName: "Mac A", endpoint: "http://100.64.0.10:8787", lastSuccessfulAt: nil),
            ConnectionProfile(id: "mac-b", displayName: "Mac B", endpoint: "http://100.64.0.20:8787", lastSuccessfulAt: nil)
        ]
        defaults.set(try JSONEncoder().encode(profiles), forKey: "agentd.connectionProfiles.v1")
        defaults.set("mac-a", forKey: "agentd.activeConnectionProfileID.v1")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        keychain.setData(Data("token-b".utf8), account: "agentd-profile.mac-b")
        let appStore = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        let project = makeProject(id: "proj_profile_switch")
        let running = makeSession(id: "sess_profile_switch", projectID: project.id, title: "旧 Mac 会话", status: "running", source: "codex")
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
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
        store.takeOverSession(running)
        await store.selectSession(running)
        let oldSocket = try XCTUnwrap(sockets.first)
        oldSocket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        let validatedAt = Date(timeIntervalSince1970: 1_720_000_000)

        let changed = try store.commitPreparedConnection(PreparedConnectionSettings(
            endpoint: profiles[1].endpoint,
            token: "token-b",
            profileTarget: .existingProfile(id: "mac-b"),
            validatedAt: validatedAt
        ))

        XCTAssertTrue(changed)
        XCTAssertEqual(appStore.activeConnectionProfileID, "mac-b")
        XCTAssertEqual(appStore.endpoint, profiles[1].endpoint)
        XCTAssertEqual(appStore.token, "token-b")
        XCTAssertEqual(appStore.activeConnectionProfile?.lastSuccessfulAt, validatedAt)
        XCTAssertEqual(oldSocket.disconnectCallCount, 1)
        XCTAssertEqual(sockets.count, 1, "提交只退役旧连接，不应同时连接两台 Mac")
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.selectedSessionID)
    }

    func testConnectionProfileSwitchKeychainFailureKeepsOldConnection() async throws {
        let suiteName = "ConversationDataFlowTests.ProfileSwitchKeychainFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = [
            ConnectionProfile(id: "mac-a", displayName: "Mac A", endpoint: "http://100.64.0.10:8787", lastSuccessfulAt: nil),
            ConnectionProfile(id: "mac-b", displayName: "Mac B", endpoint: "http://100.64.0.20:8787", lastSuccessfulAt: nil)
        ]
        defaults.set(try JSONEncoder().encode(profiles), forKey: "agentd.connectionProfiles.v1")
        defaults.set("mac-a", forKey: "agentd.activeConnectionProfileID.v1")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        keychain.setData(Data("token-b".utf8), account: "agentd-profile.mac-b")
        let appStore = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        let project = makeProject(id: "proj_profile_keychain_failure")
        let running = makeSession(id: "sess_profile_keychain_failure", projectID: project.id, title: "必须保留", status: "running", source: "codex")
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
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
        store.takeOverSession(running)
        await store.selectSession(running)
        let oldSocket = try XCTUnwrap(sockets.first)
        oldSocket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        keychain.forcedUpdateStatus = errSecInteractionNotAllowed

        XCTAssertThrowsError(try store.commitPreparedConnection(PreparedConnectionSettings(
            endpoint: profiles[1].endpoint,
            token: "token-b",
            profileTarget: .existingProfile(id: "mac-b")
        )))

        XCTAssertEqual(appStore.activeConnectionProfileID, "mac-a")
        XCTAssertEqual(appStore.endpoint, profiles[0].endpoint)
        XCTAssertEqual(appStore.token, "token-a")
        XCTAssertEqual(oldSocket.disconnectCallCount, 0)
        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertEqual(store.sessions.map(\.id), [running.id])
        XCTAssertEqual(store.selectedSessionID, running.id)
    }

    func testConnectionProfileValidationFailureNeverRetiresOldConnection() async throws {
        let suiteName = "ConversationDataFlowTests.ProfileSwitchValidationFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = [
            ConnectionProfile(id: "mac-a", displayName: "Mac A", endpoint: "http://100.64.0.10:8787", lastSuccessfulAt: nil),
            ConnectionProfile(id: "mac-b", displayName: "Mac B", endpoint: "http://100.64.0.20:8787", lastSuccessfulAt: nil)
        ]
        defaults.set(try JSONEncoder().encode(profiles), forKey: "agentd.connectionProfiles.v1")
        defaults.set("mac-a", forKey: "agentd.activeConnectionProfileID.v1")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        keychain.setData(Data("token-b".utf8), account: "agentd-profile.mac-b")
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            routeProbeTimeout: 0.1,
            routeProbe: { _, _, _ in
                throw URLError(.cannotConnectToHost)
            }
        )
        let project = makeProject(id: "proj_profile_validation_failure")
        let running = makeSession(id: "sess_profile_validation_failure", projectID: project.id, title: "旧连接", status: "running", source: "codex")
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
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
        store.takeOverSession(running)
        await store.selectSession(running)
        let oldSocket = try XCTUnwrap(sockets.first)
        oldSocket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        appStore.connectionStatus = .connected("旧 Mac")
        appStore.lastError = "旧连接现场"

        do {
            _ = try await store.switchConnectionProfile(id: "mac-b")
            XCTFail("目标 Mac 验证失败时不应提交切换")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }

        XCTAssertEqual(appStore.activeConnectionProfileID, "mac-a")
        XCTAssertEqual(appStore.token, "token-a")
        XCTAssertEqual(appStore.connectionStatus, .connected("旧 Mac"))
        XCTAssertEqual(appStore.lastError, "旧连接现场")
        XCTAssertEqual(oldSocket.disconnectCallCount, 0)
        XCTAssertEqual(store.selectedSessionID, running.id)
        XCTAssertEqual(sockets.count, 1)
    }

    func testConcurrentProfileChangeIsRejectedAndCancelledChangeCannotCommit() async throws {
        let fixture = try await makeConnectedProfileFixture(testName: "ConcurrentCancel")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let gate = PreparedConnectionGate()
        let prepared = PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "token-b",
            profileTarget: .existingProfile(id: "mac-b")
        )
        let firstTask = Task { @MainActor in
            try await fixture.store.performPreparedConnectionChange {
                await gate.wait()
                return prepared
            }
        }
        await gate.waitUntilStarted()

        var didRunSecondPrepare = false
        do {
            _ = try await fixture.store.performPreparedConnectionChange {
                didRunSecondPrepare = true
                return prepared
            }
            XCTFail("已有连接切换时不应启动第二个 prepare")
        } catch let error as ConnectionProfileError {
            XCTAssertEqual(error, .operationInProgress)
        }
        XCTAssertFalse(didRunSecondPrepare)

        firstTask.cancel()
        await gate.release()
        do {
            _ = try await firstTask.value
            XCTFail("已取消任务不能越过提交门")
        } catch is CancellationError {
            // 预期路径。
        }

        XCTAssertEqual(fixture.appStore.activeConnectionProfileID, "mac-a")
        XCTAssertEqual(fixture.appStore.token, "token-a")
        XCTAssertEqual(fixture.socket.disconnectCallCount, 0)
        XCTAssertEqual(fixture.store.selectedSessionID, fixture.session.id)
        XCTAssertEqual(fixture.store.webSocketStatus, .connected)
    }

    func testRenamingActiveProfileDoesNotRetireWebSocketOrClearSession() async throws {
        let fixture = try await makeConnectedProfileFixture(testName: "RenameActive")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let generation = fixture.appStore.connectionGeneration
        let endpoint = fixture.appStore.endpoint
        let token = fixture.appStore.token

        XCTAssertTrue(try fixture.appStore.renameConnectionProfile(
            id: "mac-a",
            displayName: "重命名后的 Mac"
        ))

        XCTAssertEqual(fixture.appStore.activeConnectionProfile?.displayName, "重命名后的 Mac")
        XCTAssertEqual(fixture.appStore.activeConnectionProfileID, "mac-a")
        XCTAssertEqual(fixture.appStore.endpoint, endpoint)
        XCTAssertEqual(fixture.appStore.token, token)
        XCTAssertEqual(fixture.appStore.connectionGeneration, generation)
        XCTAssertEqual(fixture.appStore.connectionStatus, .connected("旧 Mac"))
        XCTAssertEqual(fixture.socket.disconnectCallCount, 0)
        XCTAssertEqual(fixture.store.webSocketStatus, .connected)
        XCTAssertEqual(fixture.store.selectedSessionID, fixture.session.id)
        XCTAssertTrue(fixture.store.sessions.contains(where: { $0.id == fixture.session.id }))
    }

    func testBackgroundInvalidatesPendingProfileChangeBeforeCommit() async throws {
        let fixture = try await makeConnectedProfileFixture(testName: "BackgroundCancel")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let gate = PreparedConnectionGate()
        let prepared = PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "token-b",
            profileTarget: .existingProfile(id: "mac-b")
        )
        let task = Task { @MainActor in
            try await fixture.store.performPreparedConnectionChange {
                await gate.wait()
                return prepared
            }
        }
        await gate.waitUntilStarted()

        fixture.store.suspendForBackground()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("退后台后不能提交仍在途的档案切换")
        } catch is CancellationError {
            // 预期路径。
        }

        XCTAssertEqual(fixture.appStore.activeConnectionProfileID, "mac-a")
        XCTAssertEqual(fixture.appStore.token, "token-a")
        XCTAssertEqual(fixture.socket.disconnectCallCount, 1, "仅允许后台生命周期退役旧 WS")
        XCTAssertEqual(fixture.store.webSocketStatus, .disconnected)
        XCTAssertEqual(fixture.store.selectedSessionID, fixture.session.id)
    }

    func testFailedProfileChangeDoesNotOverwriteCredentialTerminalStateArrivingInFlight() async throws {
        let fixture = try await makeConnectedProfileFixture(testName: "TerminalDuringSwitch")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let gate = PreparedConnectionGate()
        fixture.appStore.connectionStatus = .connected("旧 Mac")
        let task = Task { @MainActor in
            try await fixture.store.performPreparedConnectionChange {
                await gate.wait()
                throw URLError(.cannotConnectToHost)
            }
        }
        await gate.waitUntilStarted()

        fixture.socket.emitStatus(.terminated(.credentialsInvalid))
        try await waitForWebSocketStatus(.terminated(.credentialsInvalid), store: fixture.store)
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("目标档案验证应失败")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        }

        XCTAssertEqual(fixture.appStore.activeConnectionProfileID, "mac-a")
        XCTAssertEqual(fixture.store.connectionTermination, .credentialsInvalid)
        XCTAssertEqual(fixture.store.webSocketStatus, .terminated(.credentialsInvalid))
        XCTAssertEqual(
            fixture.appStore.connectionStatus,
            .failed(ConnectionTerminationStatus.credentialsInvalid.message)
        )
        XCTAssertEqual(fixture.appStore.lastError, ConnectionTerminationStatus.credentialsInvalid.message)
    }

    func testThemeStorePersistsThemePresetFontsAndFontScale() throws {
        let suiteName = "ThemeStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ThemeStore(defaults: defaults)
        XCTAssertEqual(store.mode, .system)
        XCTAssertEqual(store.preset, .codex)
        XCTAssertEqual(store.uiFontPreset, .system)
        XCTAssertEqual(store.codeFontPreset, .systemMono)
        XCTAssertEqual(store.fontScale, 1.0, accuracy: 0.001)

        let initialVersion = store.themeVersion
        store.mode = .dark
        store.preset = .gruvbox
        store.uiFontPreset = .rounded
        store.codeFontPreset = .menlo
        store.setFontScale(1.2)

        XCTAssertEqual(store.mode, .dark)
        XCTAssertEqual(store.preset, .gruvbox)
        XCTAssertEqual(store.uiFontPreset, .rounded)
        XCTAssertEqual(store.codeFontPreset, .menlo)
        XCTAssertEqual(store.fontScale, 1.2, accuracy: 0.001)
        XCTAssertGreaterThan(store.themeVersion, initialVersion)

        let reloaded = ThemeStore(defaults: defaults)
        XCTAssertEqual(reloaded.mode, .dark)
        XCTAssertEqual(reloaded.preset, .gruvbox)
        XCTAssertEqual(reloaded.uiFontPreset, .rounded)
        XCTAssertEqual(reloaded.codeFontPreset, .menlo)
        XCTAssertEqual(reloaded.fontScale, 1.2, accuracy: 0.001)
        XCTAssertEqual(reloaded.themeVersion, store.themeVersion)
    }

    func testThemeStoreClampsFontScaleAndScalesSizes() throws {
        let suiteName = "ThemeStoreScaleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ThemeStore(defaults: defaults)

        store.setFontScale(9.0)
        XCTAssertEqual(store.fontScale, ThemeStore.maximumFontScale, accuracy: 0.001)
        XCTAssertEqual(store.scaledFontSize(16), 16 * CGFloat(ThemeStore.maximumFontScale), accuracy: 0.001)

        store.setFontScale(0.1)
        XCTAssertEqual(store.fontScale, ThemeStore.minimumFontScale, accuracy: 0.001)
        XCTAssertEqual(store.scaledFontSize(20), 20 * CGFloat(ThemeStore.minimumFontScale), accuracy: 0.001)
    }

    func testConversationMessageRenderFingerprintTracksContentRevision() {
        var message = ConversationMessage(
            role: .assistant,
            content: String(repeating: "长消息", count: 4_000),
            sendStatus: .sending
        )
        let initial = message.renderFingerprint

        message.sendStatus = .confirmed
        XCTAssertEqual(message.renderFingerprint, initial)
        XCTAssertEqual(message.contentRevision, 0)

        message.content += "尾部增量"
        XCTAssertNotEqual(message.renderFingerprint, initial)
        XCTAssertEqual(message.contentRevision, 1)
        XCTAssertGreaterThan(message.contentByteCount, initial.contentByteCount)
    }

    func testConversationTimelineForcesTailFollowOnlyForLocalUserSubmissions() {
        let localSubmission = ConversationMessage(
            clientMessageID: "client-tail",
            role: .user,
            content: "继续修复滚动",
            sendStatus: .sending
        )
        XCTAssertTrue(ConversationTimelineView.shouldForceTailFollow(forNewTailMessage: localSubmission))

        let replayedHistoryUser = ConversationMessage(
            role: .user,
            content: "历史里的旧问题",
            sendStatus: .confirmed
        )
        XCTAssertFalse(ConversationTimelineView.shouldForceTailFollow(forNewTailMessage: replayedHistoryUser))

        let assistantReply = ConversationMessage(
            clientMessageID: "client-ignored",
            role: .assistant,
            content: "收到",
            sendStatus: .sending
        )
        XCTAssertFalse(ConversationTimelineView.shouldForceTailFollow(forNewTailMessage: assistantReply))

        let processSummary = ConversationMessage(
            clientMessageID: "client-process",
            role: .user,
            kind: .commandSummary,
            content: "命令：go test ./...",
            sendStatus: .sent
        )
        XCTAssertFalse(ConversationTimelineView.shouldForceTailFollow(forNewTailMessage: processSummary))
    }

    func testConversationTimelineAllowsInitialTailRetryButRespectsUserScrollAway() {
        XCTAssertTrue(ConversationTimelineView.shouldAttemptTailScroll(
            force: false,
            shouldFollowMessageTail: false,
            forceNextMessageTailScroll: true,
            isTailFollowLocked: false,
            isTimelineNearBottom: false
        ))

        XCTAssertTrue(ConversationTimelineView.shouldAttemptTailScroll(
            force: false,
            shouldFollowMessageTail: false,
            forceNextMessageTailScroll: false,
            isTailFollowLocked: false,
            isTimelineNearBottom: true
        ))

        XCTAssertFalse(ConversationTimelineView.shouldAttemptTailScroll(
            force: false,
            shouldFollowMessageTail: false,
            forceNextMessageTailScroll: false,
            isTailFollowLocked: false,
            isTimelineNearBottom: false
        ))

        XCTAssertTrue(ConversationTimelineView.shouldAttemptTailScroll(
            force: true,
            shouldFollowMessageTail: false,
            forceNextMessageTailScroll: false,
            isTailFollowLocked: false,
            isTimelineNearBottom: false
        ))

        // 切换会话时要防住旧 List 的 geometry 回调：即使它先报“不在底部”，
        // 也要继续执行尾部重锚，直到用户明确上翻。
        XCTAssertTrue(ConversationTimelineView.shouldAttemptTailScroll(
            force: false,
            shouldFollowMessageTail: false,
            forceNextMessageTailScroll: false,
            isTailFollowLocked: true,
            isTimelineNearBottom: false
        ))
    }

    func testConversationTimelineStartsAtTailAfterSwitchingFromScrolledSession() async throws {
        let firstSessionID = "tail-position-first"
        let secondSessionID = "tail-position-second"
        let conversationStore = ConversationStore()
        for index in 0..<36 {
            conversationStore.appendSystem("会话 A 消息 \(index)", sessionID: firstSessionID)
            conversationStore.appendSystem("会话 B 消息 \(index)", sessionID: secondSessionID)
        }

        let sessionStore = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        sessionStore.selectedSessionID = firstSessionID
        let themeSuiteName = "TailPositionTests.\(UUID().uuidString)"
        let themeDefaults = try XCTUnwrap(UserDefaults(suiteName: themeSuiteName))
        let themeStore = ThemeStore(defaults: themeDefaults)

        let view = ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.colorScheme, .light)
        let host = UIHostingController(rootView: view)
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 420, height: 820)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            themeDefaults.removePersistentDomain(forName: themeSuiteName)
        }

        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 700_000_000)

        let firstScrollView = try XCTUnwrap(conversationTimelineScrollView(in: host.view))
        XCTAssertLessThanOrEqual(distanceFromBottom(firstScrollView), 4)

        // 先把会话 A 人工停在顶部，再切换会话；会话 B 必须丢弃旧 contentOffset 并默认展示最新消息。
        firstScrollView.setContentOffset(
            CGPoint(x: 0, y: -firstScrollView.adjustedContentInset.top),
            animated: false
        )
        sessionStore.selectedSessionID = secondSessionID
        try await Task.sleep(nanoseconds: 900_000_000)
        host.view.layoutIfNeeded()

        let secondScrollView = try XCTUnwrap(conversationTimelineScrollView(in: host.view))
        XCTAssertLessThanOrEqual(distanceFromBottom(secondScrollView), 4)
    }

    func testConversationTimelineRapidSessionSwitchesKeepValidTailTarget() async throws {
#if targetEnvironment(macCatalyst)
        // 该回归用例专门覆盖 iOS 27 UICollectionView 的快照/IndexPath 竞态；
        // Catalyst 的 List 滚动宿主行为不同，常规会话切换与尾部跟随由相邻用例继续覆盖。
        try XCTSkipIf(true, "仅适用于 iOS 27 UICollectionView 快照竞态")
#endif
        let longSessionID = "tail-race-long"
        let shortSessionID = "tail-race-short"
        let conversationStore = ConversationStore()
        for index in 0..<72 {
            conversationStore.appendSystem("长会话消息 \(index)", sessionID: longSessionID)
        }
        for index in 0..<3 {
            conversationStore.appendSystem("短会话消息 \(index)", sessionID: shortSessionID)
        }

        let sessionStore = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        sessionStore.selectedSessionID = shortSessionID
        let themeSuiteName = "TailRaceTests.\(UUID().uuidString)"
        let themeDefaults = try XCTUnwrap(UserDefaults(suiteName: themeSuiteName))
        let themeStore = ThemeStore(defaults: themeDefaults)

        let view = ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.colorScheme, .light)
        let host = UIHostingController(rootView: view)
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 420, height: 820)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            themeDefaults.removePersistentDomain(forName: themeSuiteName)
        }

        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)

        // iOS 27 的 List 底层使用 UICollectionView；快速从 3 行切到 72 行时，
        // 不能把新尾行 ID 解析成旧快照中的 IndexPath，否则 UIKit 会直接断言崩溃。
        for index in 0..<24 {
            sessionStore.selectedSessionID = index.isMultiple(of: 2) ? longSessionID : shortSessionID
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        sessionStore.selectedSessionID = longSessionID

        // 同一会话持续追加过程项时，SwiftUI 数据已经包含新尾行，但 UICollectionView
        // 可能还在提交上一份快照；这是线上自动跟随最常见的竞态窗口。
        for index in 0..<48 {
            conversationStore.appendSystem("流式过程 \(index)", sessionID: longSessionID)
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        // 全量套件会同时制造较多 MainActor/UI 工作，固定等待 700ms 容易在 List
        // 尚未提交最终快照时提前断言。轮询只等待现有重锚逻辑收敛，不主动改滚动位置，
        // 因此仍然保留“最终必须贴底 4pt 以内”的真实验收标准。
        let scrollView = try await waitForConversationTimelineAtBottom(in: host.view)
        XCTAssertLessThanOrEqual(distanceFromBottom(scrollView), 4)
    }

    func testTimestampCaptionMarksFallbackTimes() {
        let fallback = ConversationMessage(
            role: .assistant,
            content: "历史时间缺失",
            createdAt: Date(timeIntervalSince1970: 100),
            sendStatus: .confirmed,
            isTimestampFallback: true
        )
        let normal = ConversationMessage(
            role: .assistant,
            content: "历史时间可信",
            createdAt: Date(timeIntervalSince1970: 100),
            sendStatus: .confirmed
        )

        XCTAssertEqual(fallback.timestampCaptionText, normal.timestampCaptionText)
        XCTAssertTrue(fallback.isTimestampFallback)
        XCTAssertFalse(normal.isTimestampFallback)
    }

    func testStreamingAssistantDeltaRefreshesLatestTimestamp() throws {
        let store = ConversationStore()
        let sessionID = "sess_stream_timestamp"
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let latestAt = Date(timeIntervalSince1970: 1_090)
        let baseMetadata = AgentEventMetadata(
            seq: 1,
            sessionID: sessionID,
            turnID: "turn_stream_timestamp",
            itemID: "item_stream_timestamp",
            messageID: "message_stream_timestamp",
            clientMessageID: nil,
            revision: 1,
            createdAt: startedAt
        )
        store.applyAssistantDelta(
            AgentDelta(text: "第一段", role: .assistant, kind: .message),
            metadata: baseMetadata,
            fallbackSessionID: sessionID
        )
        store.applyAssistantDelta(
            AgentDelta(text: "第二段", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 2,
                sessionID: sessionID,
                turnID: "turn_stream_timestamp",
                itemID: "item_stream_timestamp",
                messageID: "message_stream_timestamp",
                clientMessageID: nil,
                revision: 2,
                createdAt: latestAt
            ),
            fallbackSessionID: sessionID
        )
        store.appendSystem("flush pending delta", sessionID: sessionID)

        let assistant = try XCTUnwrap(store.messages(for: sessionID).first { $0.role == .assistant })
        XCTAssertEqual(assistant.content, "第一段第二段")
        XCTAssertEqual(assistant.createdAt, startedAt)
        XCTAssertEqual(assistant.updatedAt, latestAt)
        XCTAssertTrue(assistant.timestampCaptionText.contains("最近"))
    }

    func testHistoryHydrationKeepsLiveActivityPayloadWhenSnapshotLacksPayload() throws {
        let store = ConversationStore()
        let sessionID = "sess_activity_payload_merge"
        let turnID = "turn_activity_payload_merge"
        let itemID = "cmd_activity_payload_merge"
        let item: [String: CodexAppServerJSONValue] = [
            "type": .string("commandExecution"),
            "id": .string(itemID),
            "command": .string("go test ./..."),
            "cwd": .string("/tmp/activity"),
            "status": .string("completed"),
            "commandActions": .array([.object(["name": .string("search"), "query": .string("ConversationStore")])]),
            "aggregatedOutput": .string("ok"),
            "exitCode": .int(0)
        ]
        let payload = try XCTUnwrap(ConversationActivityPayload(item: item))
        let stableID = "appserver:\(turnID):\(itemID)"
        let createdAt = Date(timeIntervalSince1970: 100)
        store.completeMessage(
            AgentMessage(
                id: stableID,
                sessionID: sessionID,
                turnID: turnID,
                itemID: itemID,
                role: .system,
                kind: .commandSummary,
                content: payload.summaryText,
                activityPayload: payload,
                createdAt: createdAt,
                revision: 1
            ),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: turnID,
                itemID: itemID,
                messageID: stableID,
                clientMessageID: nil,
                revision: 1,
                createdAt: createdAt
            ),
            fallbackSessionID: sessionID
        )

        store.setHistory([
            CodexHistoryMessage(
                id: stableID,
                role: "system",
                kind: .commandSummary,
                content: payload.summaryText,
                createdAt: createdAt,
                turnID: turnID,
                itemID: itemID,
                timelineOrdinal: 1
            )
        ], sessionID: sessionID)

        let message = try XCTUnwrap(store.messages(for: sessionID).first)
        XCTAssertEqual(message.activityPayload, payload)
        XCTAssertEqual(message.activityPayload?.displayTitle, "搜索 ConversationStore")
        XCTAssertEqual(message.content, payload.summaryText)
    }

    func testActivityPresentationHidesProtocolNoiseAndKeepsRawDiagnostics() throws {
        let failedTool: [String: CodexAppServerJSONValue] = [
            "type": .string("mcpToolCall"),
            "id": .string("tool_xcode_test"),
            "server": .string("xcodebuildmcp"),
            "tool": .string("test_sim"),
            "status": .string("failed")
        ]
        let failedPayload = try XCTUnwrap(ConversationActivityPayload(item: failedTool))

        XCTAssertEqual(failedPayload.displayTitle, "运行模拟器测试")
        XCTAssertEqual(failedPayload.toolName, "xcodebuildmcp.test_sim", "底层工具标识仍保留给诊断数据")
        XCTAssertEqual(failedPayload.displayStatusText, "失败")
        XCTAssertTrue(failedPayload.isFailure)
        XCTAssertEqual(failedPayload.summaryText, "工具：运行模拟器测试\n状态：失败")

        let futureStatus: [String: CodexAppServerJSONValue] = [
            "type": .string("dynamicToolCall"),
            "namespace": .string("future_runtime"),
            "tool": .string("unknown_action"),
            "status": .string("unknown")
        ]
        let futurePayload = try XCTUnwrap(ConversationActivityPayload(item: futureStatus))

        XCTAssertEqual(futurePayload.displayTitle, "调用工具")
        XCTAssertNil(futurePayload.displayStatusText)
        XCTAssertFalse(futurePayload.summaryText.lowercased().contains("unknown"))
        XCTAssertEqual(
            ConversationActivityPayload.plainProgressText("**Planning release build**\n`ENABLE_TESTABILITY=YES`"),
            "Planning release build\nENABLE_TESTABILITY=YES"
        )
    }

    func testFileChangeProgressUsesCompactFilenameButKeepsFullPath() throws {
        let path = "/Users/me/code/CatName/Features/Me/MeView.swift"
        let item: [String: CodexAppServerJSONValue] = [
            "type": .string("fileChange"),
            "status": .string("completed"),
            "changes": .array([.object(["path": .string(path), "kind": .string("update")])])
        ]
        let payload = try XCTUnwrap(ConversationActivityPayload(item: item))

        XCTAssertEqual(payload.displayTitle, "修改 MeView.swift")
        XCTAssertEqual(payload.filePaths, [path])
        XCTAssertEqual(payload.displayStatusText, "已完成")
    }

    func testSessionDisplayStatusUsesForegroundAndGoalProgress() {
        let goal = ThreadGoal(
            threadID: "session-1",
            objective: "完成 iPad 对话体验优化",
            status: .active,
            tokenBudget: 1_000,
            tokensUsed: 250,
            timeUsedSeconds: 75
        )
        let session = AgentSession(
            id: "session-1",
            projectID: "project-1",
            project: "Mimi",
            dir: "/tmp/mimi",
            title: "修复会话体验",
            status: SessionStatus.running.rawValue,
            source: "codex",
            resumeID: nil,
            createdAt: nil,
            updatedAt: nil,
            activeTurnID: "turn-1",
            goal: goal
        )

        XCTAssertEqual(session.displayStatus(foregroundActivity: .receivingAssistant).title, "正在回复")
        XCTAssertEqual(goal.budgetPercentText, "25%")
        XCTAssertEqual(try XCTUnwrap(goal.budgetProgressFraction), 0.25, accuracy: 0.001)
        XCTAssertTrue(session.statusBadges(foregroundActivity: .receivingAssistant).contains { badge in
            badge.title == "目标 运行中 25%"
        })

        let approvalSession = AgentSession(
            id: "session-2",
            projectID: "project-1",
            project: "Mimi",
            dir: "/tmp/mimi",
            title: "审批会话",
            status: SessionStatus.waitingForApproval.rawValue,
            source: "codex",
            resumeID: nil,
            createdAt: nil,
            updatedAt: nil,
            pendingApproval: ApprovalSummary(id: "approval-1", title: "写入文件", kind: "command", count: 1)
        )

        XCTAssertEqual(approvalSession.displayStatus(foregroundActivity: .receivingAssistant).title, "待审批")
    }

    func testSessionListSeparatesActiveLifecycleFromHistory() {
        let sessions = [
            makeSession(
                id: "running",
                projectID: "project-1",
                title: "正在执行",
                status: SessionStatus.running.rawValue,
                source: "codex"
            ),
            makeSession(
                id: "approval",
                projectID: "project-1",
                title: "等待审批",
                status: SessionStatus.waitingForApproval.rawValue,
                source: "codex"
            ),
            makeSession(
                id: "failed",
                projectID: "project-1",
                title: "执行失败",
                status: SessionStatus.failed.rawValue,
                source: "codex"
            ),
            makeSession(
                id: "history",
                projectID: "project-1",
                title: "历史会话",
                status: SessionStatus.history.rawValue,
                source: "codex"
            )
        ]

        let partition = SessionListPartition(sessions: sessions)

        XCTAssertEqual(partition.active.map(\.id), ["running", "approval"])
        XCTAssertEqual(partition.history.map(\.id), ["failed", "history"])
        XCTAssertTrue(SessionLibraryStatusFilter.active.includes(sessions[1]))
        XCTAssertTrue(SessionLibraryStatusFilter.needsAttention.includes(sessions[1]))
        XCTAssertTrue(SessionLibraryStatusFilter.history.includes(sessions[2]))
        XCTAssertTrue(SessionLibraryStatusFilter.needsAttention.includes(sessions[2]))
    }

    func testConversationFileReferenceDetectorFindsPreviewableAbsolutePaths() {
        let text = """
        已生成：
        - `/tmp/report.pdf`
        - file:///tmp/chart.png?download=1
        - /tmp/report.pdf
        - /tmp/source.swift:12
        - https://example.com/file.pdf
        - /tmp/output
        """

        let references = ConversationFileReferenceDetector.references(in: text)

        XCTAssertEqual(references.map(\.path), ["/tmp/report.pdf", "/tmp/chart.png"])
        XCTAssertEqual(references.map(\.name), ["report.pdf", "chart.png"])
    }

    func testConversationImageSourceRecognizesHistoryMediaPlaceholder() {
        let source = ConversationImageSource.markdown("agentd-history-media://media_abc")

        XCTAssertEqual(source, .historyMedia(id: "media_abc"))
    }

    func testConversationMessageEqualityAndHashIncludeTurnPayload() {
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 42)
        let firstPayload = CodexAppServerTurnPayload(input: [
            .text("看图"),
            .image(url: "data:image/png;base64,AA==", detail: .high)
        ])
        let secondPayload = CodexAppServerTurnPayload(input: [
            .text("看图"),
            .image(url: "data:image/png;base64,BBBB", detail: .high)
        ])
        let first = ConversationMessage(
            id: id,
            stableID: "message-1",
            clientMessageID: "client-1",
            turnID: "turn-1",
            itemID: "item-1",
            role: .user,
            content: "看图 [图片]",
            createdAt: createdAt,
            sendStatus: .sent,
            revision: 1,
            turnPayload: firstPayload
        )
        let second = ConversationMessage(
            id: id,
            stableID: "message-1",
            clientMessageID: "client-1",
            turnID: "turn-1",
            itemID: "item-1",
            role: .user,
            content: "看图 [图片]",
            createdAt: createdAt,
            sendStatus: .sent,
            revision: 1,
            turnPayload: secondPayload
        )

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 2)
    }

    func testTimelineBuilderCollapsesProcessMessagesBeforeCompletedAssistant() throws {
        let base = Date(timeIntervalSince1970: 1_000)
        let user = ConversationMessage(
            stableID: "user-1",
            role: .user,
            content: "检查 UI 展示",
            createdAt: base,
            sendStatus: .confirmed
        )
        let command = ConversationMessage(
            stableID: "cmd-1",
            turnID: "turn-processed",
            role: .system,
            kind: .commandSummary,
            content: "命令：xcodebuild test",
            createdAt: base.addingTimeInterval(1),
            sendStatus: .confirmed
        )
        let diff = ConversationMessage(
            stableID: "diff-1",
            turnID: "turn-processed",
            role: .system,
            kind: .fileChangeSummary,
            content: "文件变更：ConversationView.swift modified",
            createdAt: base.addingTimeInterval(4),
            sendStatus: .confirmed
        )
        let assistant = ConversationMessage(
            stableID: "assistant-1",
            turnID: "turn-processed",
            role: .assistant,
            content: "已完成，最终回答保持展开。",
            createdAt: base.addingTimeInterval(10),
            sendStatus: .confirmed
        )

        let items = ConversationTimelineItemBuilder.items(from: [user, command, diff, assistant])

        XCTAssertEqual(items.count, 4)
        if case .message(let first) = items[0] {
            XCTAssertEqual(first.content, "检查 UI 展示")
        } else {
            XCTFail("用户消息不应被折叠")
        }
        guard case .activity(let visibleCommand) = items[1] else {
            return XCTFail("真实命令应作为独立进度行")
        }
        XCTAssertEqual(visibleCommand.content, "命令：xcodebuild test")
        guard case .activity(let visibleDiff) = items[2] else {
            return XCTFail("文件变更应作为独立进度行")
        }
        XCTAssertEqual(visibleDiff.content, "文件变更：ConversationView.swift modified")
        if case .message(let final) = items[3] {
            XCTAssertEqual(final.role, .assistant)
            XCTAssertEqual(final.content, "已完成，最终回答保持展开。")
        } else {
            XCTFail("最终 assistant 消息必须保持独立展开")
        }
    }

    func testTimelineBuilderKeepsProcessGroupSeparateFromDifferentTurn() {
        let base = Date(timeIntervalSince1970: 1_500)
        let command = ConversationMessage(
            stableID: "cmd-other-turn",
            turnID: "turn-a",
            role: .system,
            kind: .commandSummary,
            content: "命令：go test ./...",
            createdAt: base,
            sendStatus: .confirmed
        )
        let assistant = ConversationMessage(
            stableID: "assistant-other-turn",
            turnID: "turn-b",
            role: .assistant,
            content: "这是另一个 turn 的最终回复。",
            createdAt: base.addingTimeInterval(5),
            sendStatus: .confirmed
        )

        let items = ConversationTimelineItemBuilder.items(from: [command, assistant])

        XCTAssertEqual(items.count, 2)
        if case .activity(let activity) = items[0] {
            XCTAssertEqual(activity.turnID, "turn-a")
        } else {
            XCTFail("过程消息应保持独立，不得并入另一个 turn 的 assistant")
        }
        if case .message(let final) = items[1] {
            XCTAssertEqual(final.turnID, "turn-b")
        } else {
            XCTFail("另一个 turn 的 assistant 必须独立展示")
        }
    }

    func testTimelineBuilderPlacesLateProcessMessagesBeforeTheirCompletedAssistant() throws {
        let base = Date(timeIntervalSince1970: 1_700)
        let user = ConversationMessage(
            stableID: "user-late-process",
            role: .user,
            content: "先出最终回复再出 diff",
            createdAt: base,
            sendStatus: .confirmed
        )
        let assistant = ConversationMessage(
            stableID: "assistant-late-process",
            turnID: "turn-late-process",
            role: .assistant,
            content: "最终回答仍然完整展示。",
            createdAt: base.addingTimeInterval(5),
            sendStatus: .confirmed
        )
        let diff = ConversationMessage(
            stableID: "diff-late-process",
            turnID: "turn-late-process",
            role: .system,
            kind: .fileChangeSummary,
            content: "文件变更：README.md modified",
            createdAt: base.addingTimeInterval(9),
            sendStatus: .confirmed
        )

        let items = ConversationTimelineItemBuilder.items(from: [user, assistant, diff])

        XCTAssertEqual(items.count, 3)
        if case .message(let first) = items[0] {
            XCTAssertEqual(first.role, .user)
        } else {
            XCTFail("用户消息应保持在首位")
        }
        guard case .activity(let visibleDiff) = items[1] else {
            return XCTFail("迟到的过程消息应按 turnID 归到最终回复之前")
        }
        XCTAssertEqual(visibleDiff.content, "文件变更：README.md modified")
        if case .message(let final) = items[2] {
            XCTAssertEqual(final.content, "最终回答仍然完整展示。")
        } else {
            XCTFail("最终 assistant 消息仍应独立展示")
        }
    }

    func testTimelineBuilderCollapsesProcessMessagesWhileAssistantIsStreaming() {
        let base = Date(timeIntervalSince1970: 2_000)
        let command = ConversationMessage(
            stableID: "cmd-streaming",
            turnID: "turn-streaming",
            role: .system,
            kind: .commandSummary,
            content: "命令仍在运行",
            createdAt: base,
            sendStatus: .confirmed
        )
        let assistant = ConversationMessage(
            stableID: "assistant-streaming",
            turnID: "turn-streaming",
            role: .assistant,
            content: "正在输出",
            createdAt: base.addingTimeInterval(2),
            sendStatus: .sending
        )

        let items = ConversationTimelineItemBuilder.items(from: [command, assistant])

        XCTAssertEqual(items.count, 2)
        guard case .activity(let visibleCommand) = items[0] else {
            return XCTFail("运行中的真实命令应作为独立进度行")
        }
        XCTAssertEqual(visibleCommand.kind, .commandSummary)
        guard case .message(let streamingAssistant) = items[1] else {
            return XCTFail("assistant streaming 内容仍应直接展示")
        }
        XCTAssertEqual(streamingAssistant.sendStatus, .sending)
    }

    func testTimelineBuilderOnlyCoalescesConsecutiveExplorationAndKeepsStableID() throws {
        let base = Date(timeIntervalSince1970: 2_100)
        let read = ConversationMessage(
            stableID: "read-active",
            turnID: "turn-exploration",
            role: .system,
            kind: .commandSummary,
            content: "命令：sed -n 1,80p App.swift",
            createdAt: base,
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "查看 App.swift",
                status: "running",
                command: "sed -n 1,80p App.swift"
            )
        )
        let search = ConversationMessage(
            stableID: "search-active",
            turnID: "turn-exploration",
            role: .system,
            kind: .commandSummary,
            content: "命令：rg ComposerView",
            createdAt: base.addingTimeInterval(1),
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "搜索 ComposerView",
                status: "running",
                command: "rg ComposerView"
            )
        )
        let build = ConversationMessage(
            stableID: "build-active",
            turnID: "turn-exploration",
            role: .system,
            kind: .commandSummary,
            content: "命令：xcodebuild test",
            createdAt: base.addingTimeInterval(2),
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "运行 xcodebuild test",
                status: "running",
                command: "xcodebuild test"
            )
        )
        let assistant = ConversationMessage(
            stableID: "assistant-exploration",
            turnID: "turn-exploration",
            role: .assistant,
            content: "检查完成。",
            createdAt: base.addingTimeInterval(3),
            sendStatus: .confirmed
        )

        let activeItems = ConversationTimelineItemBuilder.items(from: [read, search, build])
        XCTAssertEqual(activeItems.count, 2)
        let activeGroup: ConversationExplorationGroup
        if case .exploration(let group) = activeItems[0] {
            activeGroup = group
        } else {
            return XCTFail("连续读取和搜索应合并为单行探索进度")
        }
        XCTAssertEqual(activeGroup.messages.count, 2)
        XCTAssertFalse(activeGroup.isCompleted)
        guard case .activity(let visibleBuild) = activeItems[1] else {
            return XCTFail("真实构建命令必须另起一行")
        }
        XCTAssertEqual(visibleBuild.stableID, "build-active")

        let completedItems = ConversationTimelineItemBuilder.items(from: [read, search, build, assistant])
        guard case .exploration(let completedGroup) = completedItems[0] else {
            return XCTFail("完成后仍应保留探索进度行")
        }
        XCTAssertEqual(completedGroup.id, activeGroup.id)
        XCTAssertTrue(completedGroup.isCompleted)
    }

    func testTimelineBuilderDoesNotMergeExplorationAcrossTurns() {
        let base = Date(timeIntervalSince1970: 2_150)
        let first = ConversationMessage(
            stableID: "read-turn-a",
            turnID: "turn-a",
            role: .system,
            kind: .commandSummary,
            content: "命令：cat A.swift",
            createdAt: base,
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "查看 A.swift",
                status: "completed",
                command: "cat A.swift"
            )
        )
        let second = ConversationMessage(
            stableID: "read-turn-b",
            turnID: "turn-b",
            role: .system,
            kind: .commandSummary,
            content: "命令：cat B.swift",
            createdAt: base.addingTimeInterval(1),
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "查看 B.swift",
                status: "completed",
                command: "cat B.swift"
            )
        )

        let items = ConversationTimelineItemBuilder.items(from: [first, second])

        XCTAssertEqual(items.count, 2)
        guard case .exploration(let firstGroup) = items[0],
              case .exploration(let secondGroup) = items[1]
        else {
            return XCTFail("不同 turn 的探索必须保留各自的时间线身份")
        }
        XCTAssertEqual(firstGroup.messages.map(\.turnID), ["turn-a"])
        XCTAssertEqual(secondGroup.messages.map(\.turnID), ["turn-b"])
        XCTAssertNotEqual(firstGroup.id, secondGroup.id)
    }

    func testTimelineBuilderCompactsResolvedUserInputButKeepsPendingInputVisible() {
        let base = Date(timeIntervalSince1970: 2_180)
        let pending = ConversationMessage(
            stableID: "input-pending",
            turnID: "turn-input",
            role: .system,
            kind: .userInput,
            content: "请选择语音语言",
            createdAt: base,
            sendStatus: .confirmed
        )
        let submitted = ConversationMessage(
            stableID: "input-submitted",
            turnID: "turn-input",
            role: .system,
            kind: .userInput,
            content: "补充信息已提交：固定中文",
            createdAt: base.addingTimeInterval(1),
            sendStatus: .confirmed
        )

        let items = ConversationTimelineItemBuilder.items(from: [pending, submitted])

        XCTAssertEqual(items.count, 2)
        guard case .message(let visiblePending) = items[0] else {
            return XCTFail("等待输入时必须保留可交互卡片")
        }
        XCTAssertEqual(visiblePending.stableID, "input-pending")
        guard case .activity(let compactSubmitted) = items[1] else {
            return XCTFail("已提交补充信息应压缩为单行里程碑")
        }
        XCTAssertEqual(compactSubmitted.stableID, "input-submitted")
    }

    func testTimelineBuilderKeepsInteractiveMessagesVisibleDuringActiveTurn() {
        let base = Date(timeIntervalSince1970: 2_200)
        let command = ConversationMessage(
            stableID: "cmd-active-interactive",
            turnID: "turn-active-interactive",
            role: .system,
            kind: .commandSummary,
            content: "命令仍在运行",
            createdAt: base,
            sendStatus: .confirmed
        )
        let approval = ConversationMessage(
            stableID: "approval-active-interactive",
            turnID: "turn-active-interactive",
            role: .system,
            kind: .approval,
            content: "需要批准运行命令",
            createdAt: base.addingTimeInterval(1),
            sendStatus: .confirmed
        )
        let assistant = ConversationMessage(
            stableID: "assistant-active-interactive",
            turnID: "turn-active-interactive",
            role: .assistant,
            content: "等待确认",
            createdAt: base.addingTimeInterval(2),
            sendStatus: .sending
        )

        let items = ConversationTimelineItemBuilder.items(from: [command, approval, assistant])

        // 命令、审批和 streaming assistant 都直接可见；审批仍然保留交互卡片。
        XCTAssertEqual(items.count, 3)
        guard case .activity(let visibleCommand) = items[0] else {
            return XCTFail("运行中的命令应作为独立进度行")
        }
        XCTAssertEqual(visibleCommand.kind, .commandSummary)
        guard case .message(let visibleApproval) = items[1] else {
            return XCTFail("运行中的审批必须保持可见可操作")
        }
        XCTAssertEqual(visibleApproval.kind, .approval)
        guard case .message(let streamingAssistant) = items[2] else {
            return XCTFail("assistant streaming 内容仍应保留")
        }
        XCTAssertEqual(streamingAssistant.sendStatus, .sending)
    }

    func testTimelineBuilderCollapsesProcessMessagesButKeepsFailedAssistantVisible() {
        let base = Date(timeIntervalSince1970: 2_500)
        let command = ConversationMessage(
            stableID: "cmd-failed",
            turnID: "turn-failed",
            role: .system,
            kind: .commandSummary,
            content: "命令执行失败",
            createdAt: base,
            sendStatus: .confirmed
        )
        let assistant = ConversationMessage(
            stableID: "assistant-failed",
            turnID: "turn-failed",
            role: .assistant,
            content: "无法完成。",
            createdAt: base.addingTimeInterval(2),
            sendStatus: .failed
        )

        let items = ConversationTimelineItemBuilder.items(from: [command, assistant])

        XCTAssertEqual(items.count, 2)
        guard case .activity(let failedCommand) = items[0] else {
            return XCTFail("失败回合的命令仍应作为独立进度行")
        }
        XCTAssertEqual(failedCommand.kind, .commandSummary)
        guard case .message(let failedAssistant) = items[1] else {
            return XCTFail("失败 assistant 必须直接可见")
        }
        XCTAssertEqual(failedAssistant.sendStatus, .failed)
    }

    func testTimelineBuilderDoesNotHideErrorMessagesInsideProcessedGroup() {
        let base = Date(timeIntervalSince1970: 3_000)
        let error = ConversationMessage(
            stableID: "error-1",
            role: .system,
            kind: .error,
            content: "运行错误：网络断开",
            createdAt: base,
            sendStatus: .confirmed
        )
        let assistant = ConversationMessage(
            stableID: "assistant-after-error",
            role: .assistant,
            content: "失败原因如上。",
            createdAt: base.addingTimeInterval(3),
            sendStatus: .confirmed
        )

        let items = ConversationTimelineItemBuilder.items(from: [error, assistant])

        XCTAssertEqual(items.count, 2)
        if case .message(let first) = items[0] {
            XCTAssertEqual(first.kind, .error)
        } else {
            XCTFail("错误消息必须直接可见")
        }
    }

    func testAppendSystemPreservesRuntimeTurnMetadata() throws {
        let store = ConversationStore()
        let sessionID = "sess-runtime-metadata"
        let metadata = AgentEventMetadata(
            seq: 9,
            sessionID: sessionID,
            turnID: "turn-runtime",
            itemID: "item-diff",
            messageID: "message-diff",
            clientMessageID: nil,
            revision: 3,
            createdAt: Date(timeIntervalSince1970: 4_000)
        )

        store.appendSystem(
            "文件变更：ConversationView.swift modified",
            sessionID: sessionID,
            kind: .fileChangeSummary,
            metadata: metadata
        )

        let message = try XCTUnwrap(store.messages(for: sessionID).first)
        XCTAssertEqual(message.turnID, "turn-runtime")
        XCTAssertEqual(message.itemID, "item-diff")
        XCTAssertEqual(message.revision, 3)
        XCTAssertEqual(message.createdAt, Date(timeIntervalSince1970: 4_000))
        XCTAssertNil(message.clientMessageID)
    }

    func testSystemRuntimeMetadataDoesNotStealUserClientMessageIndex() throws {
        let store = ConversationStore()
        let sessionID = "sess-client-index"
        let clientMessageID = "client-shared"
        store.appendLocalUser("运行测试", sessionID: sessionID, clientMessageID: clientMessageID, sendStatus: .sending)
        store.appendSystem(
            "文件变更：README.md modified",
            sessionID: sessionID,
            kind: .fileChangeSummary,
            metadata: AgentEventMetadata(
                seq: 11,
                sessionID: sessionID,
                turnID: "turn-client-index",
                itemID: "diff-client-index",
                messageID: nil,
                clientMessageID: clientMessageID,
                revision: 1,
                createdAt: nil
            )
        )

        store.updateSendStatus(clientMessageID: clientMessageID, sessionID: sessionID, status: .confirmed)

        let messages = store.messages(for: sessionID)
        let user = try XCTUnwrap(messages.first)
        let system = try XCTUnwrap(messages.last)
        XCTAssertEqual(user.role, .user)
        XCTAssertEqual(user.sendStatus, .confirmed)
        XCTAssertEqual(system.role, .system)
        XCTAssertNil(system.clientMessageID)
    }

    func testCompletedRuntimeMessageDoesNotStealUserClientMessageIndex() throws {
        let store = ConversationStore()
        let sessionID = "sess-completed-client-index"
        let clientMessageID = "client-completed-shared"
        store.appendLocalUser("运行命令", sessionID: sessionID, clientMessageID: clientMessageID, sendStatus: .sending)
        store.completeMessage(
            AgentMessage(
                id: "tool-completed",
                sessionID: sessionID,
                clientMessageID: clientMessageID,
                turnID: "turn-completed-client-index",
                itemID: "tool-item",
                role: .tool,
                kind: .message,
                content: "go test ./...",
                // 时间戳保持不早于上面的本地回显：本测试只关注 client index 不被抢占，
                // 更早时间戳的 completed 消息如今会按时间线插回前面（有专门的排序测试覆盖）。
                createdAt: Date(),
                revision: 1,
                sendStatus: .confirmed
            ),
            metadata: .empty,
            fallbackSessionID: sessionID
        )

        store.updateSendStatus(clientMessageID: clientMessageID, sessionID: sessionID, status: .confirmed)

        let messages = store.messages(for: sessionID)
        let user = try XCTUnwrap(messages.first)
        let runtime = try XCTUnwrap(messages.last)
        XCTAssertEqual(user.role, .user)
        XCTAssertEqual(user.sendStatus, .confirmed)
        XCTAssertEqual(runtime.role, .system)
        XCTAssertEqual(runtime.kind, .commandSummary)
        XCTAssertNil(runtime.clientMessageID)
    }

    func testMessageRenderPlanCacheReusesAppendOnlyStreamingPrefix() {
        let cache = MessageRenderPlanCache(limit: 4)
        var message = ConversationMessage(
            stableID: "assistant:render",
            role: .assistant,
            content: "先解释一下\n```swift\nlet a = 1\n",
            sendStatus: .sending
        )

        let first = cache.plan(for: message)
        XCTAssertTrue(first.blocks.contains { block in
            if case let .codeBlock(language, code) = block.kind {
                return language == "swift" && code.contains("let a = 1")
            }
            return false
        })
        XCTAssertEqual(first.openTailByteOffset, "先解释一下\n".utf8.count)

        message.content += "let b = 2\n```"
        let second = cache.plan(for: message)

        XCTAssertEqual(cache.incrementalReuseCountForTesting, 1)
        XCTAssertEqual(second.messageKey, "assistant:render")
        XCTAssertTrue(second.blocks.contains { block in
            if case let .codeBlock(language, code) = block.kind {
                return language == "swift" && code.contains("let b = 2")
            }
            return false
        })
    }

    func testThemeSwitchDuringStreamingDoesNotRebuildConversationData() throws {
        let suiteName = "ThemeStoreStreamingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let conversationStore = ConversationStore()
        let themeStore = ThemeStore(defaults: defaults)
        let sessionID = "sess_theme_streaming"
        let metadata = AgentEventMetadata(
            seq: 12,
            sessionID: sessionID,
            turnID: "turn_theme",
            itemID: "assistant_theme",
            messageID: "message_theme",
            clientMessageID: nil,
            revision: 1,
            createdAt: nil
        )

        conversationStore.applyAssistantDelta(
            AgentDelta(text: "```swift\nlet theme = \"dark\"\n```", role: .assistant, kind: .message),
            metadata: metadata,
            fallbackSessionID: sessionID
        )
        let beforeMessages = conversationStore.messages(for: sessionID)
        let beforePlan = try XCTUnwrap(beforeMessages.first).renderFingerprint
        let renderPlan = MessageRenderPlanCache(limit: 4).plan(for: try XCTUnwrap(beforeMessages.first))

        themeStore.mode = .dark
        themeStore.preset = .gruvbox
        themeStore.uiFontPreset = .rounded
        themeStore.setFontScale(1.2)

        let afterMessages = conversationStore.messages(for: sessionID)
        XCTAssertEqual(afterMessages.map(\.id), beforeMessages.map(\.id))
        XCTAssertEqual(afterMessages.map(\.stableID), beforeMessages.map(\.stableID))
        XCTAssertEqual(try XCTUnwrap(afterMessages.first).renderFingerprint, beforePlan)
        XCTAssertEqual(conversationStore.lastSeenSeq(for: sessionID), 12)
        XCTAssertEqual(MessageRenderPlanCache(limit: 4).plan(for: try XCTUnwrap(afterMessages.first)).blocks, renderPlan.blocks)
    }

    func testEventReducerActorProducesBatchedStoreMutations() async {
        let reducer = EventReducer()
        let metadata = AgentEventMetadata(
            seq: 44,
            sessionID: "sess_reducer",
            turnID: "turn_reducer",
            itemID: "item_reducer",
            messageID: "message_reducer",
            clientMessageID: nil,
            revision: 2,
            createdAt: nil
        )

        let output = await reducer.reduce(
            .assistantDelta(AgentDelta(text: "后台 reducer 输出 mutation", role: .assistant, kind: .message), metadata),
            fallbackSessionID: "fallback",
            outputIdleClearDelay: 80_000_000
        )

        XCTAssertEqual(output.foregroundUpdates.count, 1)
        XCTAssertEqual(output.activeTurnMutations.count, 1)
        XCTAssertEqual(output.logAppends.count, 0)
        XCTAssertEqual(output.messageMutations.count, 1)
        if case .assistantDelta(let delta, let returnedMetadata, let fallbackSessionID) = output.messageMutations[0] {
            XCTAssertEqual(delta.text, "后台 reducer 输出 mutation")
            XCTAssertEqual(returnedMetadata.seq, 44)
            XCTAssertEqual(fallbackSessionID, "fallback")
        } else {
            XCTFail("Expected assistant delta mutation")
        }
    }

    func testEventReducerReportsEachUnsupportedEventTypeOnlyOnce() async {
        let reducer = EventReducer()

        let first = await reducer.reduce(
            .unknown("future/progress"),
            fallbackSessionID: "session",
            outputIdleClearDelay: 0
        )
        let duplicate = await reducer.reduce(
            .unknown("future/progress"),
            fallbackSessionID: "session",
            outputIdleClearDelay: 0
        )
        let nextType = await reducer.reduce(
            .unknown("future/status"),
            fallbackSessionID: "session",
            outputIdleClearDelay: 0
        )

        XCTAssertEqual(first.logAppends.count, 1)
        XCTAssertTrue(first.logAppends[0].text.contains("已忽略暂不支持的事件：future/progress"))
        XCTAssertTrue(duplicate.logAppends.isEmpty)
        XCTAssertEqual(nextType.logAppends.count, 1)
    }

    func testEventReducerRoutesRuntimeErrorToOwningSessionAndMarksFailed() async throws {
        let reducer = EventReducer()
        let metadata = AgentEventMetadata(
            seq: 45,
            sessionID: "claude_thread",
            turnID: "claude_turn",
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )

        let output = await reducer.reduce(
            .error(
                AgentErrorPayload(message: "Invalid authentication credentials", code: "authentication_failed", retryable: false),
                metadata
            ),
            fallbackSessionID: "wrong_fallback",
            outputIdleClearDelay: 80_000_000
        )

        XCTAssertEqual(output.statusUpdates.first?.0, "claude_thread")
        XCTAssertEqual(output.statusUpdates.first?.1, SessionStatus.failed.rawValue)
        XCTAssertEqual(output.foregroundClears, ["claude_thread"])
        XCTAssertEqual(output.errorMessage, "Invalid authentication credentials")
        if case .system(let text, let sessionID, let kind, _) = try XCTUnwrap(output.messageMutations.first) {
            XCTAssertEqual(sessionID, "claude_thread")
            XCTAssertEqual(kind, .error)
            XCTAssertTrue(text.contains("Invalid authentication credentials"))
        } else {
            XCTFail("Expected runtime error system message")
        }
    }

    func testLargeDiffPanelItemsDeduplicateAndCollapseTail() throws {
        let old = ConversationMessage(
            role: .system,
            kind: .fileChangeSummary,
            content: "文件变更：Sources/App.swift modified\n旧 diff",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let longBody = String(repeating: "+ changed line\n", count: 180) + "tail-marker"
        let latest = ConversationMessage(
            role: .system,
            kind: .fileChangeSummary,
            content: "文件变更：Sources/App.swift modified\n\(longBody)",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let other = ConversationMessage(
            role: .system,
            kind: .fileChangeSummary,
            content: "文件变更：Sources/Other.swift added\nsmall diff",
            createdAt: Date(timeIntervalSince1970: 15)
        )

        let items = DiffPanelItem.items(from: [old, latest, other])
        let appItem = try XCTUnwrap(items.first { $0.fileKey == "Sources/App.swift" })

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(appItem.count, 2)
        XCTAssertEqual(appItem.title, "文件变更 x2")
        XCTAssertTrue(appItem.wasCollapsed)
        XCTAssertLessThanOrEqual(appItem.latestContent.count, 1_200)
        XCTAssertTrue(appItem.latestContent.hasSuffix("tail-marker"))
        XCTAssertTrue(appItem.displaySubtitle.contains("已折叠长 diff"))
    }

    func testComposerStateRapidTypingDoesNotPublishGlobalStores() {
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        var conversationPublishCount = 0
        var logPublishCount = 0
        let conversationCancellable = conversationStore.objectWillChange.sink {
            conversationPublishCount += 1
        }
        let logCancellable = logStore.objectWillChange.sink {
            logPublishCount += 1
        }

        var composerState = ComposerState()
        for _ in 0..<500 {
            composerState.draft.append("字")
        }

        XCTAssertEqual(composerState.draft.count, 500)
        XCTAssertTrue(composerState.canSubmit(isLoading: false))
        XCTAssertEqual(conversationPublishCount, 0)
        XCTAssertEqual(logPublishCount, 0)
        withExtendedLifetime((conversationCancellable, logCancellable)) {}
    }

    func testComposerStateInsertsPluginMentionWithoutUsingFileMentionPayload() {
        var composerState = ComposerState()

        composerState.insertPluginMention("  GitHub  ")
        XCTAssertEqual(composerState.draft, "@GitHub ")
        XCTAssertTrue(composerState.attachments.isEmpty)

        composerState.draft += "检查这个 PR"
        composerState.insertPluginMention("Linear")
        XCTAssertEqual(composerState.draft, "@GitHub 检查这个 PR @Linear ")
        XCTAssertTrue(composerState.attachments.isEmpty)
    }

    func testComposerStateTracksSubmitEligibilityWithoutTrimmingDraft() {
        var composerState = ComposerState()

        composerState.draft = " \n\t "
        XCTAssertFalse(composerState.canSubmit(isLoading: false))

        composerState.draft = " \n\t 执行一次诊断"
        XCTAssertTrue(composerState.canSubmit(isLoading: false))
        XCTAssertFalse(composerState.canSubmit(isLoading: true))

        _ = composerState.takeDraftForSubmit(isLoading: false)
        XCTAssertEqual(composerState.draft, "")
        XCTAssertFalse(composerState.canSubmit(isLoading: false))

        composerState.restore("继续检查输入卡顿")
        XCTAssertTrue(composerState.canSubmit(isLoading: false))
    }

    func testComposerStateBuildsStructuredPayloadAndRestoresAttachments() throws {
        var composerState = ComposerState()
        composerState.draft = "看下这张图"
        composerState.addAttachment(.image(url: "data:image/png;base64,AA==", detail: .high))
        composerState.addAttachment(.mention(name: "README", path: "/tmp/project/README.md"))
        composerState.turnOptions.model = "gpt-5-codex"
        composerState.turnOptions.reasoningEffort = .high

        let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(isLoading: false))

        XCTAssertTrue(composerState.draft.isEmpty)
        XCTAssertTrue(composerState.attachments.isEmpty)
        XCTAssertEqual(submitted.payload.textPrompt, "看下这张图")
        XCTAssertEqual(submitted.payload.input.count, 3)
        XCTAssertEqual(submitted.payload.options.model, "gpt-5-codex")
        XCTAssertEqual(submitted.payload.options.reasoningEffort, .high)

        composerState.restore(submitted)
        XCTAssertEqual(composerState.draft, "看下这张图")
        XCTAssertEqual(composerState.attachments.count, 2)
        XCTAssertTrue(composerState.canSubmit(isLoading: false))
    }

    func testComposerPermissionModeAppliesSafePresets() {
        var composerState = ComposerState()

        composerState.applyPermissionMode(.readOnly)
        XCTAssertEqual(composerState.permissionMode, .readOnly)
        XCTAssertEqual(composerState.turnOptions.approvalPolicy, .onRequest)
        XCTAssertEqual(composerState.turnOptions.approvalsReviewer, "user")
        XCTAssertEqual(composerState.turnOptions.sandboxMode, .readOnly)
        XCTAssertFalse(composerState.turnOptions.networkAccess)

        composerState.applyPermissionMode(.autoApprove)
        XCTAssertEqual(composerState.permissionMode, .autoApprove)
        XCTAssertEqual(composerState.turnOptions.approvalPolicy, .onFailure)
        XCTAssertEqual(composerState.turnOptions.approvalsReviewer, "auto_review")
        XCTAssertEqual(composerState.turnOptions.sandboxMode, .workspaceWrite)
        XCTAssertFalse(composerState.turnOptions.networkAccess)

        composerState.applyPermissionMode(.requestApproval)
        XCTAssertEqual(composerState.permissionMode, .requestApproval)
        XCTAssertEqual(composerState.turnOptions.approvalPolicy, .onRequest)
        XCTAssertEqual(composerState.turnOptions.approvalsReviewer, "user")
        XCTAssertEqual(composerState.turnOptions.sandboxMode, .workspaceWrite)

        composerState.applyPermissionMode(.fullAccess)
        XCTAssertEqual(composerState.permissionMode, .fullAccess)
        XCTAssertEqual(composerState.turnOptions.approvalPolicy, .onRequest)
        XCTAssertEqual(composerState.turnOptions.approvalsReviewer, "user")
        XCTAssertEqual(composerState.turnOptions.sandboxMode, .dangerFullAccess)
        XCTAssertFalse(composerState.turnOptions.networkAccess)
    }

    func testComposerCanInitializeWithGlobalDefaultPermissionMode() {
        let composerState = ComposerState(defaultPermissionMode: .requestApproval)

        XCTAssertEqual(composerState.permissionMode, .requestApproval)
        XCTAssertEqual(composerState.turnOptions.approvalPolicy, .onRequest)
        XCTAssertEqual(composerState.turnOptions.approvalsReviewer, "user")
        XCTAssertEqual(composerState.turnOptions.sandboxMode, .workspaceWrite)
        XCTAssertFalse(composerState.turnOptions.networkAccess)
        XCTAssertEqual(ComposerPermissionMode.stored("missing"), .fullAccess)
    }

    func testComposerDefaultsToFullAccessWithApproval() {
        let composerState = ComposerState()

        XCTAssertNil(composerState.turnOptions.model)
        XCTAssertEqual(composerState.turnOptions.reasoningEffort, .xhigh)
        XCTAssertEqual(composerState.permissionMode, .fullAccess)
        XCTAssertEqual(composerState.turnOptions.approvalPolicy, .onRequest)
        XCTAssertEqual(composerState.turnOptions.approvalsReviewer, "user")
        XCTAssertEqual(composerState.turnOptions.sandboxMode, .dangerFullAccess)
        XCTAssertFalse(composerState.turnOptions.networkAccess)
    }

    func testComposerStateResetsTransientSendModeForSessionSwitch() {
        var composerState = ComposerState()

        composerState.toggleGoalMode()
        XCTAssertTrue(composerState.isGoalModeSelected)
        composerState.resetTransientSendMode()
        XCTAssertFalse(composerState.isGoalModeSelected)
        XCTAssertEqual(composerState.sendMode, .standard)

        composerState.togglePlanMode()
        XCTAssertTrue(composerState.isPlanModeSelected)
        composerState.resetTransientSendMode()
        XCTAssertFalse(composerState.isPlanModeSelected)
        XCTAssertEqual(composerState.sendMode, .standard)
    }

    func testSessionStoreRetainsComposerSendModeAcrossComposerRecreation() {
        let sessionStore = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore()
        )
        let scope = ComposerDraftScopeKey.session("thread-a")
        sessionStore.saveComposerSendMode(.goal, for: scope)

        // 模拟横屏令 ComposerView 重建：新 ComposerState 从同一个 SessionStore 恢复。
        var recreatedComposer = ComposerState()
        let restoredMode = sessionStore.composerSendModeForScopeActivation(
            previousScope: .none,
            nextScope: scope,
            currentMode: .standard,
            isOptimisticSessionHandoff: false
        )
        recreatedComposer.setSendMode(restoredMode)

        XCTAssertTrue(recreatedComposer.isGoalModeSelected, "横竖屏导致 View 重建时应恢复同一会话的目标模式")
    }

    func testComposerSendModeResetsForRealScopeSwitch() {
        let previousScope = ComposerDraftScopeKey.session("thread-a")
        let nextScope = ComposerDraftScopeKey.session("thread-b")
        var cache = ComposerSendModeCache()
        cache.save(.plan, for: previousScope)

        let restoredMode = cache.modeForScopeActivation(
            previousScope: previousScope,
            nextScope: nextScope,
            currentMode: .plan,
            isOptimisticSessionHandoff: false
        )

        XCTAssertEqual(restoredMode, .standard, "真正切换会话时不能带入上一会话的计划模式")
    }

    func testComposerSendModeSurvivesOptimisticSessionIDHandoff() {
        var cache = ComposerSendModeCache()
        cache.save(.plan, for: .session("local:thread-a"))

        let restoredMode = cache.modeForScopeActivation(
            previousScope: .session("local:thread-a"),
            nextScope: .session("thread-a"),
            currentMode: .plan,
            isOptimisticSessionHandoff: true
        )

        XCTAssertEqual(restoredMode, .plan)
    }

    func testComposerStateOptionUpdatePreservesDraftAndSendMode() {
        var composerState = ComposerState()
        composerState.draft = "切换选项后继续输入"
        composerState.setSendMode(.goal)

        composerState.updateTurnOptions { options in
            options.runtimeProvider = "codex"
            options.model = "gpt-5.6-sol"
            options.modelProvider = "openai"
            options.reasoningEffort = .high
        }

        XCTAssertEqual(composerState.turnOptions.runtimeProvider, "codex")
        XCTAssertEqual(composerState.turnOptions.model, "gpt-5.6-sol")
        XCTAssertEqual(composerState.turnOptions.modelProvider, "openai")
        XCTAssertEqual(composerState.turnOptions.reasoningEffort, .high)
        XCTAssertEqual(composerState.draft, "切换选项后继续输入")
        XCTAssertTrue(composerState.isGoalModeSelected)
    }

    func testComposerDraftCacheKeepsDraftsScopedToSessionOrNewProject() {
        let sessionScope = ComposerDraftScopeKey.current(selectedSessionID: "thread-a", selectedProjectID: "project-1")
        let newProjectScope = ComposerDraftScopeKey.current(selectedSessionID: nil, selectedProjectID: "project-1")
        var cache = ComposerDraftCache()
        let sessionDraft = ComposerDraftSnapshot(
            text: "只属于 thread-a 的草稿",
            attachments: [.mention(name: "README", path: "/repo/README.md")],
            voiceDraftNeedsReview: false
        )
        let projectDraft = ComposerDraftSnapshot(
            text: "项目新会话草稿",
            attachments: [],
            voiceDraftNeedsReview: true
        )

        cache.save(sessionDraft, for: sessionScope)
        cache.save(projectDraft, for: newProjectScope)

        XCTAssertEqual(cache.snapshot(for: sessionScope), sessionDraft)
        XCTAssertEqual(cache.snapshot(for: newProjectScope), projectDraft)
        XCTAssertEqual(
            cache.snapshot(for: .session("thread-b")),
            .empty,
            "切到其他会话时不能复用上一个输入框里的草稿"
        )

        cache.save(.empty, for: sessionScope)
        XCTAssertEqual(cache.snapshot(for: sessionScope), .empty)
    }

    func testSessionStoreRetainsComposerDraftAcrossComposerRecreation() {
        let sessionStore = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore()
        )
        let scope = ComposerDraftScopeKey.session("thread-draft-recreation")
        let expected = ComposerDraftSnapshot(
            text: "窗口变化后继续保留这段草稿",
            attachments: [
                .image(url: "data:image/jpeg;base64,AA==", detail: .auto),
                .image(url: "data:image/jpeg;base64,AQ==", detail: .auto)
            ],
            voiceDraftNeedsReview: false
        )

        sessionStore.saveComposerDraft(expected, for: scope)

        // 模拟 ComposerView 被窗口布局重建：新的 ComposerState 从稳定的 SessionStore 恢复。
        var recreatedComposer = ComposerState()
        recreatedComposer.restoreDraftSnapshot(sessionStore.composerDraft(for: scope))
        XCTAssertEqual(recreatedComposer.draftSnapshot(), expected)

        sessionStore.removeComposerDraft(for: scope)
        XCTAssertEqual(sessionStore.composerDraft(for: scope), .empty)
    }

}
