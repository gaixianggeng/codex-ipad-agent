import XCTest
import Security
@testable import MimiRemote

@MainActor
final class TailscaleStableHostnameTests: XCTestCase {
    func testLegacyProfileMigrationInfersAutomaticAndCustomizedDisplayNames() throws {
        let automatic = try JSONDecoder().decode(
            ConnectionProfile.self,
            from: Data(#"{"id":"auto","displayName":"100.64.0.10","endpoint":"http://100.64.0.10:8787","revision":0}"#.utf8)
        )
        let customized = try JSONDecoder().decode(
            ConnectionProfile.self,
            from: Data(#"{"id":"custom","displayName":"工作室","endpoint":"http://100.64.0.20:8787","revision":0}"#.utf8)
        )

        XCTAssertFalse(automatic.isDisplayNameCustomized)
        XCTAssertEqual(automatic.displayName, "100.64.0.10")
        XCTAssertTrue(customized.isDisplayNameCustomized)
        XCTAssertEqual(customized.displayName, "工作室")
        XCTAssertNil(automatic.tailscaleDNSName)
        XCTAssertEqual(automatic.connectionCandidates, ["http://100.64.0.10:8787"])
    }

    func testConnectionProfilePrefersMagicDNSAndKeepsIPFallback() throws {
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "100.64.0.10",
            endpoint: "http://100.64.0.10:8787",
            tailscaleDNSName: "Studio-Mac.tailnet.ts.net.",
            tailscaleDeviceName: "studio-mac",
            isDisplayNameCustomized: false,
            lastSuccessfulAt: nil,
            installationID: "installation-a"
        )

        XCTAssertEqual(profile.displayName, "studio-mac")
        XCTAssertEqual(profile.tailscaleDNSName, "studio-mac.tailnet.ts.net")
        XCTAssertEqual(
            profile.connectionCandidates,
            [
                "http://studio-mac.tailnet.ts.net:8787",
                "http://100.64.0.10:8787",
            ]
        )
        XCTAssertEqual(profile.endpoint, "http://100.64.0.10:8787")
    }

    func testLANOnlyProfileIgnoresAdvertisedTailscaleMetadata() {
        let profile = ConnectionProfile(
            id: "lan-mac",
            displayName: "192.168.1.20",
            endpoint: "http://192.168.1.20:8787",
            tailscaleDNSName: "studio-mac.tailnet.ts.net",
            tailscaleDeviceName: "studio-mac",
            isDisplayNameCustomized: false,
            lastSuccessfulAt: nil,
            installationID: "installation-lan"
        )

        XCTAssertNil(profile.tailscaleDNSName)
        XCTAssertNil(profile.tailscaleDeviceName)
        XCTAssertEqual(profile.displayName, "192.168.1.20")
        XCTAssertEqual(profile.connectionCandidates, ["http://192.168.1.20:8787"])
    }

    func testPreparationTriesMagicDNSBeforeIPAndCommitsSuccessfulFallbackRoute() async throws {
        let suiteName = "TailscaleStableHostnameTests.CandidateFallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = ConnectionRouteProbeRecorder()
        let keychain = TestKeychainOperations()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            prefersLocalConnection: false,
            routeProbe: { endpoint, _, _ in
                await recorder.record(endpoint)
                if endpoint.contains("old-mac.tailnet.ts.net") {
                    throw URLError(.cannotFindHost)
                }
            }
        )

        let prepared = try await store.prepareConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "token-b",
            tailscaleDNSName: "old-mac.tailnet.ts.net",
            tailscaleDeviceName: "old-mac"
        )
        XCTAssertNil(store.connectionAttemptSummary)
        _ = try await store.commitConnectionSettings(prepared)
        let probedEndpoints = await recorder.endpoints()

        XCTAssertEqual(
            probedEndpoints,
            [
                "http://old-mac.tailnet.ts.net:8787",
                "http://100.64.0.20:8787",
            ]
        )
        XCTAssertEqual(prepared.endpoint, "http://100.64.0.20:8787")
        XCTAssertEqual(prepared.activeEndpoint, "http://100.64.0.20:8787")
        XCTAssertEqual(store.activeConnectionProfile?.displayName, "old-mac")
        XCTAssertEqual(store.activeConnectionProfile?.endpoint, "http://100.64.0.20:8787")
        XCTAssertEqual(store.connectionEndpoint, "http://100.64.0.20:8787")
        XCTAssertEqual(try store.client().endpoint, "http://100.64.0.20:8787")
        let summary = try XCTUnwrap(store.connectionAttemptSummary)
        XCTAssertEqual(
            summary.attempts,
            [
                ConnectionRouteAttempt(
                    endpoint: "http://old-mac.tailnet.ts.net:8787",
                    result: .failed(.dnsResolutionFailed)
                ),
                ConnectionRouteAttempt(
                    endpoint: "http://100.64.0.20:8787",
                    result: .succeeded
                ),
            ]
        )
        XCTAssertEqual(summary.outcome, .connected(activeEndpoint: "http://100.64.0.20:8787"))
        XCTAssertEqual(summary.fallbackMessage, L10n.text("ui.connection_automatically_used_saved_address"))
    }

    func testMetadataRefreshRequiresStableIdentityAndPreservesCustomName() throws {
        let suiteName = "TailscaleStableHostnameTests.MetadataRefresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "我的工作室",
            endpoint: "http://100.64.0.10:8787",
            tailscaleDNSName: "old.tailnet.ts.net",
            tailscaleDeviceName: "old",
            isDisplayNameCustomized: true,
            lastSuccessfulAt: nil,
            installationID: "installation-a"
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))

        XCTAssertNil(store.refreshConnectionProfileHostMetadata(
            profileID: profile.id,
            expectedRevision: profile.revision,
            version: VersionResponse(
                name: "agentd",
                version: "test",
                installationID: "different-installation",
                tailscaleDNSName: "wrong.tailnet.ts.net",
                tailscaleDeviceName: "wrong"
            )
        ))
        let refreshed = try XCTUnwrap(store.refreshConnectionProfileHostMetadata(
            profileID: profile.id,
            expectedRevision: profile.revision,
            version: VersionResponse(
                name: "agentd",
                version: "test",
                installationID: "installation-a",
                tailscaleDNSName: "new.tailnet.ts.net",
                tailscaleDeviceName: "new"
            )
        ))

        XCTAssertEqual(refreshed.displayName, "我的工作室")
        XCTAssertTrue(refreshed.isDisplayNameCustomized)
        XCTAssertEqual(refreshed.tailscaleDNSName, "new.tailnet.ts.net")
        XCTAssertEqual(
            refreshed.connectionCandidates,
            ["http://new.tailnet.ts.net:8787", "http://100.64.0.10:8787"]
        )
    }

    func testConnectionPreflightFallsBackFromSavedDNSNameToIP() async throws {
        let suiteName = "TailscaleStableHostnameTests.PreflightFallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "studio",
            endpoint: "http://100.64.0.10:8787",
            tailscaleDNSName: "studio.tailnet.ts.net",
            tailscaleDeviceName: "studio",
            isDisplayNameCustomized: false,
            lastSuccessfulAt: nil,
            installationID: "installation-a"
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        let recorder = ConnectionRouteProbeRecorder()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            routeProbeTimeout: 0.1,
            prefersLocalConnection: false,
            routeProbe: { endpoint, _, _ in
                await recorder.record(endpoint)
                if endpoint.contains("studio.tailnet.ts.net") {
                    throw URLError(.cannotFindHost)
                }
            }
        )

        let connected = await store.preflightConnection()
        let probedEndpoints = await recorder.endpoints()

        XCTAssertTrue(connected)
        XCTAssertEqual(
            probedEndpoints,
            [
                "http://studio.tailnet.ts.net:8787",
                "http://100.64.0.10:8787",
            ]
        )
        XCTAssertEqual(store.connectionEndpoint, "http://100.64.0.10:8787")
        XCTAssertEqual(try store.client().endpoint, "http://100.64.0.10:8787")
        let summary = try XCTUnwrap(store.connectionAttemptSummary)
        XCTAssertEqual(
            summary.attempts.map(\.endpoint),
            ["http://studio.tailnet.ts.net:8787", "http://100.64.0.10:8787"]
        )
        XCTAssertEqual(
            summary.attempts.map(\.result),
            [.failed(.dnsResolutionFailed), .succeeded]
        )
    }

    func testConnectionPreflightFallsBackWhenDNSPointsToDifferentInstallation() async throws {
        let suiteName = "TailscaleStableHostnameTests.IdentityFallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "studio",
            endpoint: "http://100.64.0.10:8787",
            tailscaleDNSName: "studio.tailnet.ts.net",
            tailscaleDeviceName: "studio",
            isDisplayNameCustomized: false,
            lastSuccessfulAt: nil,
            installationID: "installation-a"
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        let recorder = ConnectionRouteProbeRecorder()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            routeProbeTimeout: 0.1,
            prefersLocalConnection: false,
            routeProbe: { endpoint, _, _ in
                await recorder.record(endpoint)
            },
            routeVersionProbe: { endpoint, _, _ in
                VersionResponse(
                    name: "agentd",
                    version: "test",
                    installationID: endpoint.contains("studio.tailnet.ts.net")
                        ? "different-installation"
                        : "installation-a"
                )
            }
        )

        let connected = await store.preflightConnection()
        let probedEndpoints = await recorder.endpoints()

        XCTAssertTrue(connected)
        XCTAssertEqual(
            probedEndpoints,
            [
                "http://studio.tailnet.ts.net:8787",
                "http://100.64.0.10:8787",
            ]
        )
        XCTAssertEqual(store.connectionEndpoint, "http://100.64.0.10:8787")
        XCTAssertEqual(try store.client().endpoint, "http://100.64.0.10:8787")
        let summary = try XCTUnwrap(store.connectionAttemptSummary)
        XCTAssertEqual(
            summary.attempts.map(\.result),
            [.failed(.identityMismatch), .succeeded]
        )
    }

    func testLANOnlyFailureUsesCurrentReachableNetworkGuidance() async throws {
        let suiteName = "TailscaleStableHostnameTests.LANFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in throw URLError(.timedOut) }
        )

        do {
            _ = try await store.prepareConnectionSettings(
                endpoint: "http://192.168.1.20:8787",
                token: "token-lan"
            )
            XCTFail("LAN-only timeout should fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }

        let summary = try XCTUnwrap(store.connectionAttemptSummary)
        XCTAssertEqual(summary.attempts.count, 1)
        XCTAssertEqual(summary.attempts.first?.routeKind, .localNetwork)
        XCTAssertEqual(summary.attempts.first?.result, .failed(.unreachable))
        XCTAssertEqual(summary.failureGuidance, L10n.text("ui.connection_local_network_guidance"))
    }

    func testAllTailscaleCandidatesUnavailableKeepConditionalGuidanceAndOrder() async throws {
        let suiteName = "TailscaleStableHostnameTests.AllUnavailable.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: { endpoint, _, _ in
                throw URLError(endpoint.contains(".ts.net") ? .cannotFindHost : .cannotConnectToHost)
            }
        )

        do {
            _ = try await store.prepareConnectionSettings(
                endpoint: "http://100.64.0.20:8787",
                token: "token-tail",
                tailscaleDNSName: "studio.tailnet.ts.net"
            )
            XCTFail("all unavailable candidates should fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }

        let summary = try XCTUnwrap(store.connectionAttemptSummary)
        XCTAssertEqual(
            summary.attempts.map(\.endpoint),
            ["http://studio.tailnet.ts.net:8787", "http://100.64.0.20:8787"]
        )
        XCTAssertEqual(
            summary.attempts.map(\.result),
            [.failed(.dnsResolutionFailed), .failed(.unreachable)]
        )
        XCTAssertEqual(summary.failureGuidance, L10n.text("ui.connection_conditional_tailscale_guidance"))
        XCTAssertFalse(try XCTUnwrap(summary.failureGuidance).contains("未启用"))
        XCTAssertFalse(try XCTUnwrap(summary.failureGuidance).lowercased().contains("disabled"))
    }

    func testPreflightDoesNotActivateCandidatesWithMismatchedIdentity() async throws {
        let suiteName = "TailscaleStableHostnameTests.AllIdentityMismatch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "studio",
            endpoint: "http://100.64.0.10:8787",
            tailscaleDNSName: "studio.tailnet.ts.net",
            tailscaleDeviceName: "studio",
            lastSuccessfulAt: nil,
            installationID: "installation-a"
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            routeProbeTimeout: 0.1,
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in },
            routeVersionProbe: { _, _, _ in
                VersionResponse(
                    name: "agentd",
                    version: "test",
                    installationID: "different-installation"
                )
            }
        )

        let connected = await store.preflightConnection()
        XCTAssertFalse(connected)
        let summary = try XCTUnwrap(store.connectionAttemptSummary)
        XCTAssertEqual(
            summary.attempts.map(\.result),
            [.failed(.identityMismatch), .failed(.identityMismatch)]
        )
        XCTAssertEqual(summary.failureGuidance, L10n.text("ui.connection_identity_mismatch_guidance"))
        XCTAssertEqual(store.connectionEndpoint, "http://studio.tailnet.ts.net:8787")
    }

    func testNextConnectionAttemptReplacesPreviousFailureSummary() async throws {
        let suiteName = "TailscaleStableHostnameTests.SummaryReset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let plan = ConnectionAttemptProbePlan()
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in try await plan.probe() }
        )

        do {
            _ = try await store.prepareConnectionSettings(
                endpoint: "http://192.168.1.20:8787",
                token: "token-lan"
            )
            XCTFail("first attempt should fail")
        } catch {
            XCTAssertEqual(store.connectionAttemptSummary?.attempts.first?.result, .failed(.unreachable))
        }

        await plan.allowSuccess()
        let prepared = try await store.prepareConnectionSettings(
            endpoint: "http://192.168.1.20:8787",
            token: "token-lan"
        )
        XCTAssertNil(store.connectionAttemptSummary)
        _ = try await store.commitConnectionSettings(prepared)
        let summary = try XCTUnwrap(store.connectionAttemptSummary)
        XCTAssertEqual(summary.attempts.map(\.result), [.succeeded])
        XCTAssertNil(summary.failureGuidance)
        XCTAssertNil(summary.fallbackMessage)
    }

    func testConnectionOverviewPresentationNeverExposesRawEndpoint() {
        let endpoint = "http://192.168.1.20:8787"
        let fallbackProfile = ConnectionProfile(
            id: "lan-fallback",
            displayName: "192.168.1.20",
            endpoint: endpoint,
            isDisplayNameCustomized: false,
            lastSuccessfulAt: nil
        )
        let endpointNamedProfile = ConnectionProfile(
            id: "endpoint-name",
            displayName: endpoint,
            endpoint: endpoint,
            isDisplayNameCustomized: true,
            lastSuccessfulAt: nil
        )

        for profile in [fallbackProfile, endpointNamedProfile] {
            let summary = ConnectionOverviewPresentation.summary(
                isConfigured: true,
                profile: profile
            )
            let row = ConnectionProfileRowPresentation(profile: profile)
            let forgetConfirmation = ConnectionCredentialRemovalConfirmation.forgettingCurrent(profile)
            let deleteConfirmation = ConnectionCredentialRemovalConfirmation.deletingSavedProfile(profile)
            XCTAssertFalse(summary.contains(endpoint))
            XCTAssertFalse(summary.contains("192.168.1.20"))
            XCTAssertEqual(summary, L10n.text("ui.connection_profile_reachable_network"))
            for value in [
                row.title,
                row.routeDetail,
                row.copyAccessibilityLabel,
                row.manageAccessibilityLabel,
                forgetConfirmation.message,
                deleteConfirmation.title,
                deleteConfirmation.message,
            ] {
                XCTAssertFalse(value.contains(endpoint))
                XCTAssertFalse(value.contains("192.168.1.20"))
            }
        }

        let namedProfile = ConnectionProfile(
            id: "named",
            displayName: "工作室 Mac",
            endpoint: endpoint,
            isDisplayNameCustomized: true,
            lastSuccessfulAt: nil
        )
        XCTAssertEqual(
            ConnectionOverviewPresentation.summary(isConfigured: true, profile: namedProfile),
            "工作室 Mac"
        )
        let namedRow = ConnectionProfileRowPresentation(profile: namedProfile)
        XCTAssertEqual(namedRow.title, "工作室 Mac")
        XCTAssertTrue(namedRow.copyAccessibilityLabel.contains("工作室 Mac"))
        XCTAssertTrue(namedRow.manageAccessibilityLabel.contains("工作室 Mac"))
        XCTAssertEqual(
            ConnectionOverviewPresentation.summary(isConfigured: false, profile: fallbackProfile),
            L10n.text("ui.mac_connection_not_configured_yet")
        )
    }

    func testProfileSwitchMissingTokenClearsOldTerminalStateAndFencesStaleGeneration() async throws {
        let suiteName = "TailscaleStableHostnameTests.SwitchMissingToken.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-b",
            displayName: "备用 Mac",
            endpoint: "http://192.168.1.20:8787",
            lastSuccessfulAt: nil
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in XCTFail("缺少访问码时不应进入路由探测") }
        )
        let staleGeneration = seedStaleConnectionTerminal(in: store)

        do {
            _ = try await store.prepareConnectionProfileSwitch(id: profile.id)
            XCTFail("缺少访问码应在路由探测前失败")
        } catch {
            XCTAssertEqual(error as? ConnectionProfileError, .missingToken)
        }

        assertConnectionTerminalCleared(store)
        store.finishConnectionAttempt(
            generation: staleGeneration,
            attempts: [ConnectionRouteAttempt(endpoint: profile.endpoint, result: .succeeded)],
            outcome: .connected(activeEndpoint: profile.endpoint)
        )
        XCTAssertNil(store.connectionAttemptSummary)
    }

    func testProfileSwitchKeychainReadFailureClearsOldTerminalState() async throws {
        let suiteName = "TailscaleStableHostnameTests.SwitchKeychainFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-b",
            displayName: "备用 Mac",
            endpoint: "http://192.168.1.20:8787",
            lastSuccessfulAt: nil
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        let keychain = TestKeychainOperations(forcedCopyStatus: errSecInteractionNotAllowed)
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in XCTFail("Keychain 读取失败时不应进入路由探测") }
        )
        _ = seedStaleConnectionTerminal(in: store)

        do {
            _ = try await store.prepareConnectionProfileSwitch(id: profile.id)
            XCTFail("Keychain 读取失败应立即返回")
        } catch let error as TokenStoreError {
            guard case .loadFailed(let status) = error else {
                return XCTFail("应返回 Keychain 读取失败")
            }
            XCTAssertEqual(status, errSecInteractionNotAllowed)
        }

        assertConnectionTerminalCleared(store)
    }

    func testPairingTicketClaimFailureClearsOldTerminalStateBeforeAwait() async throws {
        let recorder = ConnectionRouteProbeRecorder()
        let store = AppStore(
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            pairingTicketClaim: { _ in throw URLError(.cannotConnectToHost) },
            routeProbe: { endpoint, _, _ in await recorder.record(endpoint) }
        )
        let staleGeneration = seedStaleConnectionTerminal(in: store)
        let url = try XCTUnwrap(URL(
            string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787&issued_at=2026-06-29T10%3A00%3A00Z&expires_at=4102444800&pair_sig=abcdef"
        ))

        do {
            _ = try await store.preparePairingURL(url)
            XCTFail("ticket claim 失败时不应进入路由探测")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        }

        assertConnectionTerminalCleared(store)
        let probedEndpoints = await recorder.endpoints()
        XCTAssertEqual(probedEndpoints, [])
        store.finishConnectionAttempt(
            generation: staleGeneration,
            attempts: [ConnectionRouteAttempt(endpoint: "http://100.64.0.1:8787", result: .succeeded)],
            outcome: .connected(activeEndpoint: "http://100.64.0.1:8787")
        )
        XCTAssertNil(store.connectionAttemptSummary)
    }

    func testProfileSwitchAndTicketPairingReuseOneAttemptGeneration() async throws {
        let suiteName = "TailscaleStableHostnameTests.GenerationHandoff.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-b",
            displayName: "备用 Mac",
            endpoint: "http://192.168.1.20:8787",
            lastSuccessfulAt: nil
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("saved-access-code".utf8), account: "agentd-profile.mac-b")
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            prefersLocalConnection: false,
            pairingTicketClaim: { ticket in
                PairingCredentials(endpoint: ticket.endpoint, token: "ticket-access-code")
            },
            routeProbe: { _, _, _ in }
        )

        let initialGeneration = store.beginConnectionAttempt()
        let switchPrepared = try await store.prepareConnectionProfileSwitch(id: profile.id)
        let switchGeneration = try XCTUnwrap(switchPrepared.connectionAttemptGeneration)
        XCTAssertEqual(switchGeneration, initialGeneration &+ 1)
        XCTAssertNil(store.connectionAttemptSummary)

        let ticketURL = try XCTUnwrap(URL(
            string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787&issued_at=2026-06-29T10%3A00%3A00Z&expires_at=4102444800&pair_sig=abcdef"
        ))
        let pairingPrepared = try await store.preparePairingURL(ticketURL)
        let pairingGeneration = try XCTUnwrap(pairingPrepared.connectionAttemptGeneration)
        XCTAssertEqual(pairingGeneration, switchGeneration &+ 1)
        XCTAssertNil(store.connectionAttemptSummary)
    }

    func testNewAttemptClearsVisibleErrorTerminationAndRejectsStaleGeneration() throws {
        let suiteName = "TailscaleStableHostnameTests.VisibleErrorReset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false
        )
        let staleGeneration = store.beginConnectionAttempt()
        store.finishConnectionAttempt(
            generation: staleGeneration,
            attempts: [
                ConnectionRouteAttempt(
                    endpoint: "http://192.168.1.20:8787",
                    result: .failed(.unreachable)
                ),
            ],
            outcome: .failed
        )
        store.markCredentialsInvalid()
        XCTAssertNotNil(store.lastError)
        XCTAssertNotNil(store.connectionTermination)
        XCTAssertNotNil(store.connectionAttemptSummary)

        let currentGeneration = store.beginConnectionAttempt()
        XCTAssertNil(store.lastError)
        XCTAssertNil(store.connectionTermination)
        XCTAssertNil(store.connectionAttemptSummary)

        store.finishConnectionAttempt(
            generation: staleGeneration,
            attempts: [
                ConnectionRouteAttempt(
                    endpoint: "http://192.168.1.99:8787",
                    result: .failed(.unreachable)
                ),
            ],
            outcome: .failed
        )
        XCTAssertNil(store.connectionAttemptSummary)

        store.finishConnectionAttempt(
            generation: currentGeneration,
            attempts: [
                ConnectionRouteAttempt(
                    endpoint: "http://192.168.1.20:8787",
                    result: .succeeded
                ),
            ],
            outcome: .connected(activeEndpoint: "http://192.168.1.20:8787")
        )
        XCTAssertEqual(store.connectionAttemptSummary?.outcome, .connected(activeEndpoint: "http://192.168.1.20:8787"))
    }

    func testCancelledPreparationLeavesNoAttemptSummary() async throws {
        let store = AppStore(
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in
                try await Task.sleep(for: .seconds(30))
            }
        )
        let task = Task {
            try await store.prepareConnectionSettings(
                endpoint: "http://192.168.1.20:8787",
                token: "token-lan"
            )
        }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled preparation should not succeed")
        } catch is CancellationError {
            // 预期取消：prepare 的取消路径必须清掉尚未提交的瞬态摘要。
        }
        XCTAssertNil(store.connectionAttemptSummary)
    }

    func testCommitFailureDoesNotPublishPreparedSuccessSummary() async throws {
        let suiteName = "TailscaleStableHostnameTests.CommitFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = TestKeychainOperations(forcedAddStatus: errSecInteractionNotAllowed)
        let store = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in },
            allowsEphemeralLocalCredentialFallback: false
        )

        let prepared = try await store.prepareConnectionSettings(
            endpoint: "https://agent.example.com",
            token: "token-remote"
        )
        XCTAssertNil(store.connectionAttemptSummary)

        do {
            _ = try await store.commitConnectionSettings(prepared)
            XCTFail("Keychain failure should reject commit")
        } catch {
            XCTAssertNil(store.connectionAttemptSummary)
            XCTAssertFalse(store.isConfigured)
        }
    }

    private func seedStaleConnectionTerminal(in store: AppStore) -> UInt64 {
        let generation = store.beginConnectionAttempt()
        store.finishConnectionAttempt(
            generation: generation,
            attempts: [
                ConnectionRouteAttempt(
                    endpoint: "http://192.168.1.99:8787",
                    result: .failed(.unreachable)
                ),
            ],
            outcome: .failed
        )
        store.markCredentialsInvalid()
        XCTAssertNotNil(store.connectionAttemptSummary)
        XCTAssertNotNil(store.lastError)
        XCTAssertNotNil(store.connectionTermination)
        return generation
    }

    private func assertConnectionTerminalCleared(_ store: AppStore) {
        XCTAssertNil(store.connectionAttemptSummary)
        XCTAssertNil(store.lastError)
        XCTAssertNil(store.connectionTermination)
    }
}

private actor ConnectionAttemptProbePlan {
    private var shouldFail = true

    func probe() throws {
        if shouldFail {
            throw URLError(.timedOut)
        }
    }

    func allowSuccess() {
        shouldFail = false
    }
}
