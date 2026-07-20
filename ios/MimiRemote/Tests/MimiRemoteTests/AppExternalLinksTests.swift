import XCTest
@testable import MimiRemote

final class AppExternalLinksTests: XCTestCase {
    func testPublicLinksUseHTTPSAndExpectedRepository() {
        let links = [
            AppExternalLinks.marketing,
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

    func testLegalDocumentsAreBundledForOfflineAccess() {
        for document in LegalDocument.allCases {
            XCTAssertNotNil(
                Bundle.main.url(forResource: document.resourceName, withExtension: "md"),
                "Missing bundled legal document: \(document.resourceName).md"
            )
        }
    }
}
