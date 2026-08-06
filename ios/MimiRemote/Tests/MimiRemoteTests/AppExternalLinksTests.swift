import XCTest
@testable import MimiRemote

final class AppExternalLinksTests: XCTestCase {
    func testPublicLinksUseHTTPSAndExpectedRepository() {
        let links = [
            AppExternalLinks.marketing,
            AppExternalLinks.macRelease,
            AppExternalLinks.macInstaller,
            AppExternalLinks.windowsRelease,
            AppExternalLinks.privacyPolicy,
            AppExternalLinks.termsOfUse,
            AppExternalLinks.support
        ]

        for link in links {
            XCTAssertEqual(link.scheme, "https")
            XCTAssertEqual(link.host, "github.com")
            XCTAssertTrue(link.path.hasPrefix("/gaixianggeng/mimi-remote"))
            XCTAssertNil(link.query)
            XCTAssertNil(link.fragment)
        }
    }

    func testLegalLinksPointToVersionedPublicDocuments() {
        XCTAssertTrue(AppExternalLinks.privacyPolicy.path.hasSuffix("/docs/privacy-policy.md"))
        XCTAssertTrue(AppExternalLinks.termsOfUse.path.hasSuffix("/docs/terms-of-use.md"))
        XCTAssertTrue(AppExternalLinks.support.path.hasSuffix("/docs/support.md"))
    }

    func testMacInstallerLinksRemainVersionIndependent() {
        XCTAssertEqual(AppExternalLinks.macRelease.path, "/gaixianggeng/mimi-remote/releases/latest")
        XCTAssertTrue(AppExternalLinks.macInstaller.path.hasSuffix("/releases/latest/download/Mimi-Remote-Mac.dmg"))
    }

    func testWindowsInstallerUsesStableLatestReleasePage() {
        XCTAssertEqual(AppExternalLinks.windowsRelease.path, "/gaixianggeng/mimi-remote/releases/latest")
    }

    func testHostInstallationPlatformsSelectMatchingDownloadEntry() {
        XCTAssertEqual(HostInstallationPlatform.allCases, [.mac, .windows])
        XCTAssertEqual(HostInstallationPlatform.mac.installerURL, AppExternalLinks.macInstaller)
        XCTAssertEqual(HostInstallationPlatform.mac.releaseURL, AppExternalLinks.macRelease)
        XCTAssertEqual(HostInstallationPlatform.windows.installerURL, AppExternalLinks.windowsRelease)
        XCTAssertEqual(HostInstallationPlatform.windows.releaseURL, AppExternalLinks.windowsRelease)
    }

    func testLegalDocumentsAreBundledForOfflineAccess() {
        for document in LegalDocument.allCases {
            XCTAssertNotNil(
                Bundle.main.url(forResource: document.resourceName, withExtension: "md"),
                "Missing bundled legal document: \(document.resourceName).md"
            )
        }
    }
}
