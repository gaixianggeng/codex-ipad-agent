import Foundation
import XCTest
@testable import MimiRemote

final class ProtocolContractTests: XCTestCase {
    func testSharedServerFixturesCoverCurrentPreviousAndIncompatibleWindows() throws {
        let current = try decodeVersionFixture("version-current.json")
        XCTAssertEqual(current.protocolRevision, MimiProtocolContract.currentRevision)
        XCTAssertEqual(
            current.minimumClientProtocolRevision,
            MimiProtocolContract.minimumSupportedClientRevision
        )
        XCTAssertEqual(Set(current.capabilities), MimiProtocolContract.declaredCapabilities)
        XCTAssertEqual(
            current.capabilityNegotiation.decision(for: "file_upload_v1"),
            .enabled
        )
        XCTAssertNoThrow(try current.requireCompatible())

        let previous = try decodeVersionFixture("version-previous.json")
        XCTAssertEqual(previous.protocolRevision, MimiProtocolContract.legacyServerRevision)
        XCTAssertEqual(
            previous.minimumClientProtocolRevision,
            MimiProtocolContract.minimumSupportedClientRevision
        )
        XCTAssertTrue(previous.capabilities.isEmpty, "旧服务缺少 capability 时必须安全降级为空集合")
        XCTAssertEqual(
            previous.capabilityNegotiation.decision(for: "file_upload_v1"),
            .serverUnsupported
        )
        XCTAssertNoThrow(try previous.requireCompatible())

        let incompatible = try decodeVersionFixture("version-incompatible.json")
        XCTAssertThrowsError(try incompatible.requireCompatible()) { error in
            guard case ProtocolCompatibilityError.clientTooOld(
                let clientRevision,
                let minimumClientRevision,
                let serverRevision
            ) = error else {
                return XCTFail("不兼容服务端应返回可诊断的版本错误，实际为 \(error)")
            }
            XCTAssertEqual(clientRevision, MimiProtocolContract.currentRevision)
            XCTAssertEqual(minimumClientRevision, 3)
            XCTAssertEqual(serverRevision, 3)
            XCTAssertTrue(error.localizedDescription.contains("3"))
        }

        let future = try decodeVersionFixture("version-unknown-capability.json")
        XCTAssertNoThrow(try future.requireCompatible())
        XCTAssertEqual(future.capabilities, ["future_safe_path_v2"])
        XCTAssertEqual(
            future.capabilityNegotiation.decision(for: "file_upload_v1"),
            .serverUnsupported,
            "未知 capability/state 不能意外打开当前客户端的文件上传路径"
        )
    }

    func testSharedClientMatrixMatchesGeneratedRESTAndWebSocketHeaders() throws {
        let matrix = try JSONDecoder().decode(
            [ClientCompatibilityFixture].self,
            from: try fixtureData("client-matrix.json")
        )
        let current = try XCTUnwrap(matrix.first { $0.name == "current_client_current_server" })
        XCTAssertEqual(current.protocolRevision, MimiProtocolContract.currentRevision)
        XCTAssertEqual(
            current.minimumServerProtocolRevision,
            MimiProtocolContract.minimumSupportedServerRevision
        )
        XCTAssertEqual(current.expectedStatus, 200)

        var request = URLRequest(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:8787/api/app-server/ws")))
        MimiProtocolContract.applyClientHeaders(to: &request)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: MimiProtocolContract.clientRevisionHeader),
            String(try XCTUnwrap(current.protocolRevision))
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: MimiProtocolContract.minimumServerRevisionHeader),
            String(try XCTUnwrap(current.minimumServerProtocolRevision))
        )

        let previous = try XCTUnwrap(matrix.first { $0.name == "previous_client_current_server" })
        XCTAssertNil(previous.protocolRevision)
        XCTAssertNil(previous.minimumServerProtocolRevision)
        XCTAssertEqual(previous.expectedStatus, 200)

        let rejected = try XCTUnwrap(matrix.first { $0.name == "newer_client_requires_newer_server" })
        XCTAssertEqual(rejected.expectedStatus, 426)
        XCTAssertEqual(rejected.expectedCode, "protocol_incompatible")
    }

    func testWebSocketUpgradeFailureKeepsDiagnosticProtocolWindow() throws {
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:8787/api/app-server/ws"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 426,
            httpVersion: "HTTP/1.1",
            headerFields: [
                MimiProtocolContract.serverRevisionHeader: "2",
                MimiProtocolContract.minimumClientRevisionHeader: "1",
            ]
        ))

        let mapped = URLSessionCodexAppServerTransport.mappedTaskError(
            URLError(.badServerResponse),
            response: response
        )
        guard case AgentAPIError.server(let status, let message) = mapped else {
            return XCTFail("426 WebSocket 握手应保留为可诊断协议错误，实际为 \(mapped)")
        }
        XCTAssertEqual(status, 426)
        XCTAssertTrue(message.contains("agentd revision=2"))
        XCTAssertTrue(message.contains(String(MimiProtocolContract.currentRevision)))
    }

    func testCriticalJourneyFixtureMatchesIOSRequestBuilders() throws {
        let fixture = try criticalJourneyContractFixture()
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.rest.pairClaim.method, "POST")
        XCTAssertEqual(fixture.rest.pairClaim.path, "/api/pair/claim")
        XCTAssertFalse(fixture.rest.pairClaim.requiresAuth)
        XCTAssertEqual(fixture.webSocket.path, "/api/app-server/ws")
        XCTAssertTrue(fixture.webSocket.requiresAuth)

        let project = AgentProject(
            id: "critical-journey",
            name: "Critical Journey",
            path: "/tmp/critical-journey"
        )
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])
        let actualClientMethods = [
            try builder.threadList(cwd: project.path).method,
            builder.threadRead(threadID: "thread-critical").method,
            try builder.threadResume(
                threadID: "thread-critical",
                cwd: project.path
            ).method,
            try builder.turnStart(
                threadID: "thread-critical",
                cwd: project.path,
                prompt: "继续"
            ).method,
            builder.turnInterrupt(
                threadID: "thread-critical",
                turnID: "turn-critical"
            ).method,
        ]
        XCTAssertEqual(actualClientMethods, fixture.webSocket.clientMethods)
        XCTAssertEqual(
            Set(fixture.webSocket.serverRequestMethods),
            [
                "item/commandExecution/requestApproval",
                "item/tool/requestUserInput",
            ]
        )
        XCTAssertEqual(
            fixture.webSocket.resolutionNotification,
            "serverRequest/resolved"
        )
    }

    private func decodeVersionFixture(_ name: String) throws -> VersionResponse {
        try AgentAPIClient.decoder.decode(VersionResponse.self, from: fixtureData(name))
    }

    private func fixtureData(_ name: String) throws -> Data {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 {
            root.deleteLastPathComponent()
        }
        return try Data(
            contentsOf: root
                .appendingPathComponent("contracts")
                .appendingPathComponent("mimi-protocol")
                .appendingPathComponent("fixtures")
                .appendingPathComponent(name)
        )
    }
}

struct CriticalJourneyContractFixture: Decodable {
    struct REST: Decodable {
        struct PairClaim: Decodable {
            let method: String
            let path: String
            let requiresAuth: Bool

            enum CodingKeys: String, CodingKey {
                case method
                case path
                case requiresAuth = "requires_auth"
            }
        }

        let pairClaim: PairClaim

        enum CodingKeys: String, CodingKey {
            case pairClaim = "pair_claim"
        }
    }

    struct WebSocket: Decodable {
        let path: String
        let requiresAuth: Bool
        let clientMethods: [String]
        let serverRequestMethods: [String]
        let resolutionNotification: String

        enum CodingKeys: String, CodingKey {
            case path
            case requiresAuth = "requires_auth"
            case clientMethods = "client_methods"
            case serverRequestMethods = "server_request_methods"
            case resolutionNotification = "resolution_notification"
        }
    }

    let schemaVersion: Int
    let rest: REST
    let webSocket: WebSocket

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case rest
        case webSocket = "websocket"
    }
}

func criticalJourneyContractFixture() throws -> CriticalJourneyContractFixture {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<4 {
        root.deleteLastPathComponent()
    }
    let data = try Data(
        contentsOf: root
            .appendingPathComponent("contracts")
            .appendingPathComponent("mimi-protocol")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("critical-journey.json")
    )
    return try JSONDecoder().decode(CriticalJourneyContractFixture.self, from: data)
}

private struct ClientCompatibilityFixture: Decodable {
    let name: String
    let protocolRevision: Int?
    let minimumServerProtocolRevision: Int?
    let expectedStatus: Int
    let expectedCode: String

    enum CodingKeys: String, CodingKey {
        case name
        case protocolRevision = "protocol_revision"
        case minimumServerProtocolRevision = "minimum_server_protocol_revision"
        case expectedStatus = "expected_status"
        case expectedCode = "expected_code"
    }
}
