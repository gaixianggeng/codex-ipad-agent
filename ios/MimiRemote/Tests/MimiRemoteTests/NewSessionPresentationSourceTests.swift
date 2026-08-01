import XCTest
@testable import MimiRemote

final class NewSessionPresentationSourceTests: XCTestCase {
    func testStableSourcesUseDistinctPresentationIdentities() {
        let toolbar = WorkbenchSheetPresentation(
            destination: .newSession,
            source: .sessionsToolbarNewSession
        )
        let sidebar = WorkbenchSheetPresentation(
            destination: .newSession,
            source: .sidebarNewSession
        )

        XCTAssertEqual(NewSessionPresentationSource.allCases.count, 2)
        XCTAssertNotEqual(
            NewSessionPresentationSource.sessionsToolbarNewSession.transitionSourceID,
            NewSessionPresentationSource.sidebarNewSession.transitionSourceID
        )
        XCTAssertNotEqual(toolbar.id, sidebar.id)
    }

    func testFallbackPresentationKeepsSourceNil() {
        var state = WorkbenchSheetPresentationState()

        state.present(.newSession)

        XCTAssertEqual(state.presentation?.destination, .newSession)
        XCTAssertNil(state.presentation?.source)
        XCTAssertEqual(state.presentation?.transition, .systemSheet)
    }

    func testDismissAndBindingResetClearPreviousSource() {
        var state = WorkbenchSheetPresentationState()
        state.present(.newSession, source: .sidebarNewSession)

        state.dismiss()
        XCTAssertNil(state.presentation)

        state.present(.newSession)
        XCTAssertNil(state.presentation?.source)

        state.present(.newSession, source: .sessionsToolbarNewSession)
        state.replace(with: nil)
        XCTAssertNil(state.presentation)
    }

    func testReduceMotionIsLockedForCurrentPresentationAndAppliedNextTime() throws {
        var state = WorkbenchSheetPresentationState()
        state.present(
            .newSession,
            source: .sessionsToolbarNewSession,
            reduceMotion: true
        )

        XCTAssertEqual(state.presentation?.transition, .systemSheet)
        XCTAssertEqual(state.presentation?.source, .sessionsToolbarNewSession)

        state.dismiss()
        state.present(
            .newSession,
            source: .sessionsToolbarNewSession,
            reduceMotion: false
        )
        XCTAssertEqual(
            state.presentation?.transition,
            .zoom(
                sourceID: NewSessionPresentationSource
                    .sessionsToolbarNewSession
                    .transitionSourceID
            )
        )
    }

    func testNonNewSessionDestinationCannotRetainNewSessionSource() {
        var state = WorkbenchSheetPresentationState()

        state.present(.settings, source: .sidebarNewSession)

        XCTAssertEqual(state.presentation?.destination, .settings)
        XCTAssertNil(state.presentation?.source)
    }

    func testActivePresentationCannotBeReenteredWithAnotherSource() {
        var state = WorkbenchSheetPresentationState()
        state.present(.newSession, source: .sessionsToolbarNewSession)

        state.present(.newSession, source: .sidebarNewSession)
        state.replace(
            with: WorkbenchSheetPresentation(
                destination: .settings,
                source: nil
            )
        )

        XCTAssertEqual(state.presentation?.destination, .newSession)
        XCTAssertEqual(state.presentation?.source, .sessionsToolbarNewSession)
    }

    func testToolbarWithoutNamespaceFailsClosedToSystemSheet() {
        XCTAssertEqual(
            NewSessionPresentationSource.sessionsToolbar(hasNamespace: true),
            .sessionsToolbarNewSession
        )
        XCTAssertNil(
            NewSessionPresentationSource.sessionsToolbar(hasNamespace: false)
        )
    }

    func testSourceCanChangeOnlyAfterDismissInBothDirections() {
        var state = WorkbenchSheetPresentationState()

        state.present(.newSession, source: .sessionsToolbarNewSession)
        state.dismiss()
        state.present(.newSession, source: .sidebarNewSession)
        XCTAssertEqual(state.presentation?.source, .sidebarNewSession)

        state.dismiss()
        state.present(.newSession, source: .sessionsToolbarNewSession)
        XCTAssertEqual(state.presentation?.source, .sessionsToolbarNewSession)
    }
}
