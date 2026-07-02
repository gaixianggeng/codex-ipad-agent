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

    func testFormatsConnectionTestDuration() {
        XCTAssertEqual(AppStore.connectionTestDurationText(milliseconds: 98), "98 ms")
        XCTAssertEqual(AppStore.connectionTestDurationText(milliseconds: 1_250), "1.2 秒")
        XCTAssertEqual(AppStore.connectionTestDurationText(milliseconds: 12_400), "12 秒")
    }
}
