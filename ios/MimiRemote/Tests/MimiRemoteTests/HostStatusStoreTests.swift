import XCTest
@testable import MimiRemote

@MainActor
final class HostStatusStoreTests: XCTestCase {
    override func tearDown() {
        HostStatusURLProtocol.reset()
        super.tearDown()
    }

    func testProbeRequestsOnlyInactiveProfileAndReusesSuccessTTL() async throws {
        let fixture = try makeFixture(
            inactiveExpectedInstallationID: "installation-b",
            returnedInstallationID: "installation-b"
        )

        fixture.statusStore.refreshIfNeeded(appStore: fixture.appStore, sessionStore: fixture.sessionStore)
        await fixture.statusStore.waitForRefreshForTesting()

        XCTAssertEqual(fixture.statusStore.status(for: fixture.inactiveProfile).state, .available)
        XCTAssertEqual(HostStatusURLProtocol.requestedHosts(), ["100.64.0.20"])
        XCTAssertEqual(HostStatusURLProtocol.requestedPaths(), ["/api/version"])

        fixture.statusStore.refreshIfNeeded(appStore: fixture.appStore, sessionStore: fixture.sessionStore)
        await fixture.statusStore.waitForRefreshForTesting()
        XCTAssertEqual(HostStatusURLProtocol.requestedHosts(), ["100.64.0.20"])
    }

    func testIdentityMismatchBecomesTerminalForUnchangedProfile() async throws {
        let fixture = try makeFixture(
            inactiveExpectedInstallationID: "installation-b",
            returnedInstallationID: "unexpected-installation"
        )

        fixture.statusStore.refreshIfNeeded(appStore: fixture.appStore, sessionStore: fixture.sessionStore)
        await fixture.statusStore.waitForRefreshForTesting()
        let firstStatus = fixture.statusStore.status(for: fixture.inactiveProfile)

        XCTAssertEqual(firstStatus.state, .identityMismatch)
        XCTAssertEqual(firstStatus.nextEligibleAt, .distantFuture)

        fixture.statusStore.refreshIfNeeded(appStore: fixture.appStore, sessionStore: fixture.sessionStore)
        await fixture.statusStore.waitForRefreshForTesting()
        XCTAssertEqual(HostStatusURLProtocol.requestedHosts().count, 1)
    }

    private func makeFixture(
        inactiveExpectedInstallationID: String,
        returnedInstallationID: String
    ) throws -> (
        appStore: AppStore,
        sessionStore: SessionStore,
        statusStore: HostStatusStore,
        inactiveProfile: ConnectionProfile
    ) {
        let suiteName = "HostStatusStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let active = ConnectionProfile(
            id: "mac-a",
            displayName: "Mac A",
            endpoint: "http://100.64.0.10:8787",
            lastSuccessfulAt: nil,
            installationID: "installation-a"
        )
        let inactive = ConnectionProfile(
            id: "mac-b",
            displayName: "Mac B",
            endpoint: "http://100.64.0.20:8787",
            lastSuccessfulAt: nil,
            installationID: inactiveExpectedInstallationID
        )
        defaults.set(try JSONEncoder().encode([active, inactive]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(active.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(active.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        keychain.setData(Data("token-b".utf8), account: "agentd-profile.mac-b")
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: keychain),
            prefersLocalConnection: false,
            routeProbe: { _, _, _ in }
        )
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore()
        )

        HostStatusURLProtocol.installationID = returnedInstallationID
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HostStatusURLProtocol.self]
        let statusStore = HostStatusStore(
            session: URLSession(configuration: configuration),
            jitter: { 1 }
        )
        return (appStore, sessionStore, statusStore, inactive)
    }
}

private final class HostStatusURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var hosts: [String] = []
    private static var paths: [String] = []
    static var installationID = "installation-b"

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.hosts.append(url.host ?? "")
        Self.paths.append(url.path)
        let installationID = Self.installationID
        Self.lock.unlock()

        let body = Data(
            #"{"name":"agentd","version":"test","installation_id":"\#(installationID)"}"#.utf8
        )
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func requestedHosts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }

    static func requestedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    static func reset() {
        lock.lock()
        hosts = []
        paths = []
        installationID = "installation-b"
        lock.unlock()
    }
}
