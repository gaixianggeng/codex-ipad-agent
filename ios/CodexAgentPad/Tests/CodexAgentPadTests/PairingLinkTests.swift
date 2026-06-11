import XCTest
@testable import CodexAgentPad

@MainActor
final class PairingLinkTests: XCTestCase {
    func testParsesEncodedPairingURL() throws {
        let url = try XCTUnwrap(URL(string: "mimi://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=0123456789abcdef0123456789abcdef"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://100.64.0.1:8787")
        XCTAssertEqual(credentials.token, "0123456789abcdef0123456789abcdef")
    }

    func testParsesConnectURL() throws {
        let url = try XCTUnwrap(URL(string: "mimi://connect?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=0123456789abcdef0123456789abcdef"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://100.64.0.1:8787")
        XCTAssertEqual(credentials.token, "0123456789abcdef0123456789abcdef")
    }

    func testParsesSingleSlashPairingURL() throws {
        let url = try XCTUnwrap(URL(string: "mimi:/pair?endpoint=100.64.0.1:8787&token=0123456789abcdef0123456789abcdef"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://100.64.0.1:8787")
    }

    func testRejectsPairingURLWithoutEndpoint() throws {
        let url = try XCTUnwrap(URL(string: "mimi://pair?token=0123456789abcdef0123456789abcdef"))

        XCTAssertThrowsError(try AppStore.pairingCredentials(from: url)) { error in
            XCTAssertEqual(error as? PairingLinkError, .missingEndpoint)
        }
    }

    func testRejectsPairingURLWithoutToken() throws {
        let url = try XCTUnwrap(URL(string: "mimi://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787"))

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
        let url = try XCTUnwrap(URL(string: "mimi://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787%2Fapi&token=0123456789abcdef0123456789abcdef"))

        XCTAssertThrowsError(try AppStore.pairingCredentials(from: url)) { error in
            XCTAssertTrue(error is AgentAPIError)
        }
    }

    func testRejectsPublicHTTPHost() throws {
        XCTAssertThrowsError(try AppStore.validatedEndpoint("http://example.com:8787")) { error in
            XCTAssertTrue(error is AgentAPIError)
        }
    }

    func testRejectsSingleLabelHTTPHost() throws {
        XCTAssertThrowsError(try AppStore.validatedEndpoint("http://macbook:8787")) { error in
            XCTAssertTrue(error is AgentAPIError)
        }
    }

    func testAllowsHTTPSPublicHost() throws {
        XCTAssertEqual(try AppStore.validatedEndpoint("https://example.com"), "https://example.com")
    }

    func testParsesLegacyCodexAgentPadScheme() throws {
        let url = try XCTUnwrap(URL(string: "codexagentpad://connect?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=0123456789abcdef0123456789abcdef"))

        let credentials = try AppStore.pairingCredentials(from: url)

        XCTAssertEqual(credentials.endpoint, "http://100.64.0.1:8787")
        XCTAssertEqual(credentials.token, "0123456789abcdef0123456789abcdef")
    }
}
