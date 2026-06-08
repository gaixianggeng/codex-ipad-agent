import XCTest
@testable import CodexAgentPad

@MainActor
final class PairingLinkTests: XCTestCase {
    func testParsesEncodedPairingURL() throws {
        let url = try XCTUnwrap(URL(string: "codexagentpad://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=0123456789abcdef0123456789abcdef"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://100.64.0.1:8787")
        XCTAssertEqual(credentials.token, "0123456789abcdef0123456789abcdef")
    }

    func testParsesSingleSlashPairingURL() throws {
        let url = try XCTUnwrap(URL(string: "codexagentpad:/pair?endpoint=100.64.0.1:8787&token=0123456789abcdef0123456789abcdef"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://100.64.0.1:8787")
    }

    func testRejectsPairingURLWithoutEndpoint() throws {
        let url = try XCTUnwrap(URL(string: "codexagentpad://pair?token=0123456789abcdef0123456789abcdef"))

        XCTAssertThrowsError(try AppStore.pairingCredentials(from: url)) { error in
            XCTAssertEqual(error as? PairingLinkError, .missingEndpoint)
        }
    }

    func testRejectsPairingURLWithoutToken() throws {
        let url = try XCTUnwrap(URL(string: "codexagentpad://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787"))

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
        let url = try XCTUnwrap(URL(string: "codexagentpad://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787%2Fapi&token=0123456789abcdef0123456789abcdef"))

        XCTAssertThrowsError(try AppStore.pairingCredentials(from: url)) { error in
            XCTAssertTrue(error is AgentAPIError)
        }
    }

    func testAllowsPlaintextOnlyForTrustedLocalOrTailscaleHosts() throws {
        XCTAssertEqual(try AppStore.validatedEndpoint("127.0.0.1:8787"), "http://127.0.0.1:8787")
        XCTAssertEqual(try AppStore.validatedEndpoint("http://localhost:8787"), "http://localhost:8787")
        XCTAssertEqual(try AppStore.validatedEndpoint("http://192.168.1.8:8787"), "http://192.168.1.8:8787")
        XCTAssertEqual(try AppStore.validatedEndpoint("http://172.20.0.2:8787"), "http://172.20.0.2:8787")
        XCTAssertEqual(try AppStore.validatedEndpoint("http://100.64.0.1:8787"), "http://100.64.0.1:8787")
        XCTAssertEqual(try AppStore.validatedEndpoint("http://[::1]:8787"), "http://[::1]:8787")
        XCTAssertEqual(try AppStore.validatedEndpoint("http://agent.tailnet.ts.net:8787"), "http://agent.tailnet.ts.net:8787")
    }

    func testRejectsPlaintextPublicEndpoint() throws {
        XCTAssertThrowsError(try AppStore.validatedEndpoint("http://example.com:8787")) { error in
            guard case AgentAPIError.insecurePlaintextEndpoint = error else {
                return XCTFail("Expected insecurePlaintextEndpoint, got \(error)")
            }
        }
    }

    func testAllowsPublicHTTPSEndpoint() throws {
        XCTAssertEqual(try AppStore.validatedEndpoint("https://example.com:8787"), "https://example.com:8787")
    }

    func testPreparePairingURLDoesNotOverwriteSavedConnectionBeforeUserSave() throws {
        let store = AppStore()
        let originalEndpoint = store.endpoint
        let originalToken = store.token
        let url = try XCTUnwrap(URL(string: "codexagentpad://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=new-token"))

        try store.preparePairingURL(url)

        XCTAssertEqual(store.endpoint, originalEndpoint)
        XCTAssertEqual(store.token, originalToken)
        XCTAssertEqual(store.pendingPairingCredentials, PairingCredentials(endpoint: "http://100.64.0.1:8787", token: "new-token"))
        XCTAssertEqual(store.consumePendingPairingCredentials(), PairingCredentials(endpoint: "http://100.64.0.1:8787", token: "new-token"))
        XCTAssertNil(store.pendingPairingCredentials)
    }

    func testATSUsesLocalNetworkingInsteadOfGlobalArbitraryLoads() throws {
        let ats = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])

        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
        XCTAssertNotEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
    }

    func testWebSocketClientRejectsLegacyPlaintextPublicEndpointBeforeConnecting() {
        let store = AppStore()
        store.endpoint = "http://example.com:8787"
        store.token = "legacy-token"
        let socket = store.makeSessionWebSocketClient()
        var statuses: [WebSocketStatus] = []
        var failures: [String] = []
        socket.onStatus = { statuses.append($0) }
        socket.onSendFailure = { _, message in failures.append(message) }

        socket.connect(sessionID: "legacy-session")
        let didFail = statuses.contains {
            if case .failed = $0 {
                return true
            }
            return false
        }

        XCTAssertTrue(didFail)
        XCTAssertFalse(socket.sendInput("hello", clientMessageID: "legacy-message"))
        XCTAssertEqual(failures.count, 1)
    }
}
