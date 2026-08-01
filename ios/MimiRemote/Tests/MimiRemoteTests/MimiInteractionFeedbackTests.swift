import XCTest
@testable import MimiRemote

final class MimiInteractionFeedbackTests: XCTestCase {
    func testEveryMotionTokenHasSpringAndReducedMotionFallback() {
        for token in MimiMotion.allCases {
            let normal = token.resolve(reduceMotion: false)
            let reduced = token.resolve(reduceMotion: true)

            guard case .spring = normal.curve else {
                return XCTFail("\(token) 普通模式必须使用可中断的 spring")
            }
            guard case .easeOut = reduced.curve else {
                return XCTFail("\(token) Reduce Motion 必须使用短淡变 fallback")
            }
            XCTAssertFalse(reduced.allowsScale)
            XCTAssertFalse(reduced.allowsSpatialMotion)
        }
    }

    func testPressOnlyAllowsScaleOutsideReducedMotion() {
        XCTAssertTrue(MimiMotion.press.resolve(reduceMotion: false).allowsScale)
        XCTAssertFalse(MimiMotion.press.resolve(reduceMotion: true).allowsScale)
        XCTAssertFalse(MimiMotion.press.resolve(reduceMotion: false).allowsSpatialMotion)
    }

    func testMotionTokensKeepDistinctSemanticCurves() {
        XCTAssertEqual(
            MimiMotion.press.resolve(reduceMotion: false).curve,
            .spring(response: 0.22, dampingFraction: 1, blendDuration: 0)
        )
        XCTAssertEqual(
            MimiMotion.stateTransition.resolve(reduceMotion: false).curve,
            .spring(response: 0.34, dampingFraction: 1, blendDuration: 0.08)
        )
        XCTAssertEqual(
            MimiMotion.presentation.resolve(reduceMotion: true).curve,
            .easeOut(duration: 0.16)
        )
        XCTAssertEqual(
            MimiMotion.gestureSettling.resolve(reduceMotion: true).curve,
            .easeOut(duration: 0.12)
        )
    }

    func testGestureSettlingReduceMotionUsesShortEaseOutWithoutSpatialOvershoot() {
        let resolution = MimiMotion.gestureSettling.resolve(reduceMotion: true)

        XCTAssertEqual(resolution.curve, .easeOut(duration: 0.12))
        XCTAssertFalse(resolution.allowsScale)
        XCTAssertFalse(resolution.allowsSpatialMotion)
    }

    func testHapticEventsMapToExactlyOneDistinctPattern() {
        let patterns = MimiHapticEvent.allCases.map(\.pattern)

        XCTAssertEqual(
            patterns,
            [.impactMedium, .notificationSuccess, .notificationError, .selection]
        )
        XCTAssertEqual(Set(patterns).count, MimiHapticEvent.allCases.count)
    }
}
