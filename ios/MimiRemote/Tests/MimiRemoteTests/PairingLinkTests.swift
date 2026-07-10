import XCTest
@testable import MimiRemote

@MainActor
final class PairingLinkTests: XCTestCase {
    func testParsesEncodedPairingURL() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=0123456789abcdef0123456789abcdef"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://100.64.0.1:8787")
        XCTAssertEqual(credentials.token, "0123456789abcdef0123456789abcdef")
    }

    func testParsesConnectURL() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://connect?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=0123456789abcdef0123456789abcdef"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://100.64.0.1:8787")
        XCTAssertEqual(credentials.token, "0123456789abcdef0123456789abcdef")
    }

    func testParsesUnexpiredPairingURL() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://connect?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=0123456789abcdef0123456789abcdef&expires_at=4102444800"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://100.64.0.1:8787")
    }

    func testParsesSignedPairingTicketWithoutLongTermToken() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787&issued_at=2026-06-29T10%3A00%3A00Z&expires_at=4102444800&pair_sig=abcdef"))

        let ticket = try XCTUnwrap(AppStore.pairingTicket(from: url))

        XCTAssertEqual(ticket.endpoint, "http://100.64.0.1:8787")
        XCTAssertEqual(ticket.issuedAt, "2026-06-29T10:00:00Z")
        XCTAssertEqual(ticket.expiresAt, "4102444800")
        XCTAssertEqual(ticket.pairSignature, "abcdef")
        XCTAssertThrowsError(try AppStore.pairingCredentials(from: url)) { error in
            XCTAssertEqual(error as? PairingLinkError, .missingToken)
        }
    }

    func testRejectsExpiredPairingURL() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://connect?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=0123456789abcdef0123456789abcdef&expires_at=1"))

        XCTAssertThrowsError(try AppStore.pairingCredentials(from: url)) { error in
            XCTAssertEqual(error as? PairingLinkError, .expired)
        }
    }

    func testParsesSingleSlashPairingURL() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote:/pair?endpoint=100.64.0.1:8787&token=0123456789abcdef0123456789abcdef"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://100.64.0.1:8787")
    }

    func testRejectsPairingURLWithoutEndpoint() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://pair?token=0123456789abcdef0123456789abcdef"))

        XCTAssertThrowsError(try AppStore.pairingCredentials(from: url)) { error in
            XCTAssertEqual(error as? PairingLinkError, .missingEndpoint)
        }
    }

    func testRejectsPairingURLWithoutToken() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787"))

        XCTAssertThrowsError(try AppStore.pairingCredentials(from: url)) { error in
            XCTAssertEqual(error as? PairingLinkError, .missingToken)
        }
    }

    func testRejectsUnsupportedScheme() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=0123456789abcdef0123456789abcdef"))

        XCTAssertThrowsError(try AppStore.pairingCredentials(from: url)) { error in
            XCTAssertEqual(error as? PairingLinkError, .unsupportedURL)
        }
    }

    func testRejectsEndpointWithPath() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787%2Fapi&token=0123456789abcdef0123456789abcdef"))

        XCTAssertThrowsError(try AppStore.pairingCredentials(from: url)) { error in
            XCTAssertTrue(error is AgentAPIError)
        }
    }

    func testRejectsPublicHTTPHost() throws {
        XCTAssertThrowsError(try AppStore.validatedEndpoint("http://example.com:8787")) { error in
            XCTAssertTrue(error is AgentAPIError)
        }
    }

    func testAllowsPublicHTTPIPv4RelayHost() throws {
        XCTAssertEqual(try AppStore.validatedEndpoint("http://14.103.53.126"), "http://14.103.53.126")
        XCTAssertEqual(try AppStore.validatedEndpoint("14.103.53.126:80"), "http://14.103.53.126:80")
    }

    func testRejectsSingleLabelHTTPHost() throws {
        XCTAssertThrowsError(try AppStore.validatedEndpoint("http://macbook:8787")) { error in
            XCTAssertTrue(error is AgentAPIError)
        }
    }

    func testRejectsInvalidHTTPIPv4Host() throws {
        XCTAssertThrowsError(try AppStore.validatedEndpoint("http://0.0.0.0:8787")) { error in
            XCTAssertTrue(error is AgentAPIError)
        }
    }

    func testAllowsHTTPSPublicHost() throws {
        XCTAssertEqual(try AppStore.validatedEndpoint("https://example.com"), "https://example.com")
    }

    func testParsesMimiRemoteScheme() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://connect?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=0123456789abcdef0123456789abcdef"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://100.64.0.1:8787")
        XCTAssertEqual(credentials.token, "0123456789abcdef0123456789abcdef")
    }

    func testParsesLegacyMimiScheme() throws {
        let url = try XCTUnwrap(URL(string: "mimi://connect?endpoint=http%3A%2F%2F192.168.31.163%3A8787&token=0123456789abcdef0123456789abcdef"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://192.168.31.163:8787")
        XCTAssertEqual(credentials.token, "0123456789abcdef0123456789abcdef")
    }

    func testConnectionCandidatesPreferPrimaryAndDeduplicateFallback() throws {
        let candidates = try AppStore.connectionCandidates(
            endpoint: "100.64.0.1:8787",
            fallbackEndpoint: "http://100.64.0.1:8787/",
            activeEndpoint: "http://100.64.0.1:8787",
            preferPrimary: true
        )

        XCTAssertEqual(candidates, ["http://100.64.0.1:8787"])
    }

    func testConnectionCandidatesKeepActiveFallbackFirstDuringRecovery() throws {
        let candidates = try AppStore.connectionCandidates(
            endpoint: "http://100.64.0.1:8787",
            fallbackEndpoint: "https://relay.example.com",
            activeEndpoint: "https://relay.example.com",
            preferPrimary: false
        )

        XCTAssertEqual(candidates, ["https://relay.example.com", "http://100.64.0.1:8787"])
    }

    func testReachableRouteFallsBackAfterPrimaryProbeFails() async throws {
        let suiteName = "PairingLinkTests.ConnectionRoute.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://100.64.0.1:8787", forKey: "agentd.endpoint")
        defaults.set("https://relay.example.com", forKey: "agentd.fallbackEndpoint")
        let recorder = ConnectionRouteProbeRecorder()
        let store = AppStore(defaults: defaults, routeProbeTimeout: 0.1) { endpoint, _, _ in
            await recorder.record(endpoint)
            if endpoint == "http://100.64.0.1:8787" {
                throw URLError(.cannotConnectToHost)
            }
        }
        store.token = "test-token"

        let selected = try await store.prepareReachableRoute(preferPrimary: true)
        let probedEndpoints = await recorder.endpoints()

        XCTAssertEqual(selected, "https://relay.example.com")
        XCTAssertEqual(probedEndpoints, ["http://100.64.0.1:8787", "https://relay.example.com"])
    }

    func testFormatsConnectionTestDuration() {
        XCTAssertEqual(AppStore.connectionTestDurationText(milliseconds: 98), "98 ms")
        XCTAssertEqual(AppStore.connectionTestDurationText(milliseconds: 1_250), "1.2 秒")
        XCTAssertEqual(AppStore.connectionTestDurationText(milliseconds: 12_400), "12 秒")
    }

    func testConnectionTestReportFindsSlowestAndFailedStage() {
        let report = ConnectionTestReport(
            startedAt: Date(timeIntervalSince1970: 0),
            totalMillis: 3_700,
            stages: [
                ConnectionTestStageTiming(kind: .health, durationMillis: 120, status: .succeeded),
                ConnectionTestStageTiming(kind: .version, durationMillis: 260, status: .failed("unauthorized")),
                ConnectionTestStageTiming(kind: .appServerConfig, durationMillis: 1_100, status: .succeeded),
                ConnectionTestStageTiming(kind: .appServerGateway, durationMillis: 2_200, status: .failed("timeout"))
            ]
        )

        XCTAssertEqual(report.slowestStage?.kind, .appServerGateway)
        XCTAssertEqual(report.failedStage?.kind, .version)
    }

    func testConnectionTestStabilitySummarizesRecentReports() throws {
        let reports = [
            ConnectionTestReport(
                startedAt: Date(timeIntervalSince1970: 0),
                totalMillis: 800,
                stages: [
                    ConnectionTestStageTiming(kind: .health, durationMillis: 80, status: .succeeded),
                    ConnectionTestStageTiming(kind: .appServerGateway, durationMillis: 200, status: .succeeded)
                ]
            ),
            ConnectionTestReport(
                startedAt: Date(timeIntervalSince1970: 1),
                totalMillis: 2_100,
                stages: [
                    ConnectionTestStageTiming(kind: .health, durationMillis: 120, status: .succeeded),
                    ConnectionTestStageTiming(kind: .appServerGateway, durationMillis: 1_700, status: .failed("timeout"))
                ]
            )
        ]

        let stabilities = AppStore.connectionTestStageStabilities(reports: reports)
        let gateway = try XCTUnwrap(stabilities.first { $0.kind == .appServerGateway })

        XCTAssertEqual(gateway.sampleCount, 2)
        XCTAssertEqual(gateway.failureCount, 1)
        XCTAssertEqual(gateway.spreadMillis, 1_500)
        XCTAssertEqual(gateway.maxMillis, 1_700)
    }

    func testRelayDiagnosticsSnapshotBuildsGatewayEvidence() throws {
        let baseline = try decodeRelayDiagnostics(totalConnections: 11, failedDials: 1)
        let snapshot = try decodeRelayDiagnostics(totalConnections: 12, failedDials: 2)
        let formatter = ISO8601DateFormatter()
        let gatewayStartedAt = try XCTUnwrap(formatter.date(from: "2026-07-03T02:24:58Z"))

        let diagnostics = ConnectionTestGatewayDiagnostics.make(
            baseline: baseline,
            snapshot: snapshot,
            gatewayStartedAt: gatewayStartedAt
        )

        XCTAssertEqual(diagnostics.totalConnectionsDelta, 1)
        XCTAssertEqual(diagnostics.failedUpstreamDialsDelta, 1)
        XCTAssertEqual(diagnostics.relatedConnection?.id, "gateway-12")
        XCTAssertEqual(diagnostics.relatedConnection?.recentRPC, [])
        XCTAssertEqual(diagnostics.latestRPC?.method, "initialize")
        XCTAssertEqual(diagnostics.latestRPC?.latencyMillis, 4_200)
        XCTAssertEqual(diagnostics.writeBackMillisMax, 480)
    }

    func testRelayDiagnosticsDecodesNullSlicesAsEmptyLists() throws {
        let json = """
        {
          "generated_at": "2026-07-03T02:25:00Z",
          "app_server_gateway": {
            "total_connections": 0,
            "active_connections": 0,
            "failed_upstream_dials": 1,
            "upstream_dial_ms_max": 6300,
            "client_to_upstream": {
              "frames": 0,
              "bytes": 0,
              "write_ms_max": 0,
              "last_write_ms": 0,
              "last_frame_bytes": 0
            },
            "upstream_to_client": {
              "frames": 0,
              "bytes": 0,
              "write_ms_max": 0,
              "last_write_ms": 0,
              "last_frame_bytes": 0
            },
            "rpc": {
              "responses": 0,
              "latency_ms_max": 0,
              "outstanding_requests": 0,
              "outstanding_ms_max": 0
            },
            "recent_connections": null,
            "active_connections_detail": null,
            "recent_rpc": null
          },
          "hints": null
        }
        """

        let diagnostics = try AgentAPIClient.decoder.decode(RelayDiagnosticsResponse.self, from: Data(json.utf8))

        XCTAssertEqual(diagnostics.hints, [])
        XCTAssertEqual(diagnostics.appServerGateway.recentConnections, [])
        XCTAssertEqual(diagnostics.appServerGateway.activeConnectionDetail, [])
        XCTAssertEqual(diagnostics.appServerGateway.recentRPC, [])
        XCTAssertEqual(diagnostics.appServerGateway.failedUpstreamDials, 1)
    }

    private func decodeRelayDiagnostics(totalConnections: Int, failedDials: Int) throws -> RelayDiagnosticsResponse {
        let json = """
        {
          "generated_at": "2026-07-03T02:25:00Z",
          "app_server_gateway": {
            "total_connections": \(totalConnections),
            "active_connections": 1,
            "failed_upstream_dials": \(failedDials),
            "upstream_dial_ms_max": 6300,
            "client_to_upstream": {
              "frames": 1,
              "bytes": 120,
              "write_ms_max": 12,
              "last_write_ms": 12,
              "last_frame_bytes": 120
            },
            "upstream_to_client": {
              "frames": 1,
              "bytes": 240,
              "write_ms_max": 480,
              "last_write_ms": 480,
              "last_frame_bytes": 240
            },
            "rpc": {
              "responses": 1,
              "latency_ms_max": 4200,
              "outstanding_requests": 0,
              "outstanding_ms_max": 0
            },
            "recent_connections": [],
            "active_connections_detail": [
              {
                "id": "gateway-12",
                "started_at": "2026-07-03T02:24:59Z",
                "duration_ms": 900,
                "upstream_dial_ms": 951,
                "client_to_upstream": {
                  "frames": 1,
                  "bytes": 120,
                  "write_ms_max": 12,
                  "last_write_ms": 12,
                  "last_frame_bytes": 120
                },
                "upstream_to_client": {
                  "frames": 1,
                  "bytes": 240,
                  "write_ms_max": 480,
                  "last_write_ms": 480,
                  "last_frame_bytes": 240
                },
                "rpc": {
                  "responses": 1,
                  "latency_ms_max": 4200,
                  "outstanding_requests": 0,
                  "outstanding_ms_max": 0
                },
                "last_client_method": "initialize"
              }
            ],
            "recent_rpc": [
              {
                "completed_at": "2026-07-03T02:25:00Z",
                "method": "initialize",
                "latency_ms": 4200,
                "request_bytes": 120,
                "response_bytes": 240
              }
            ]
          },
          "hints": ["app-server JSON-RPC 最大响应耗时 4200ms。"]
        }
        """
        return try AgentAPIClient.decoder.decode(RelayDiagnosticsResponse.self, from: Data(json.utf8))
    }
}

private actor ConnectionRouteProbeRecorder {
    private var recordedEndpoints: [String] = []

    func record(_ endpoint: String) {
        recordedEndpoints.append(endpoint)
    }

    func endpoints() -> [String] {
        recordedEndpoints
    }
}
