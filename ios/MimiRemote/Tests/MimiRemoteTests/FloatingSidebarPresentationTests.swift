import SwiftUI
import XCTest
@testable import MimiRemote

final class FloatingSidebarPresentationTests: XCTestCase {
    func testGestureStaysPendingBelowHysteresis() {
        let axis = FloatingSidebarGestureArbitration.resolve(
            current: .pending,
            translation: CGSize(width: 9, height: 1)
        )

        XCTAssertEqual(axis, .pending)
    }

    func testGestureDirectionLocksAtOnePointFourteenAndOnePointSixteenBoundaries() {
        let vertical = FloatingSidebarGestureArbitration.resolve(
            current: .pending,
            translation: CGSize(width: 11.4, height: 10)
        )
        let horizontal = FloatingSidebarGestureArbitration.resolve(
            current: .pending,
            translation: CGSize(width: 11.6, height: 10)
        )

        XCTAssertEqual(vertical, .vertical)
        XCTAssertEqual(horizontal, .horizontal)
    }

    func testVerticalLockNeverChangesToHorizontalDuringSameGesture() {
        var state = FloatingSidebarPresentationState()
        state.restore(.closed)
        let pendingAxis = state.resolveGestureAxis(
            translation: CGSize(width: 5, height: 4)
        )

        XCTAssertEqual(pendingAxis, .pending)
        XCTAssertEqual(state.renderTargetProgress, 0)
        XCTAssertEqual(state.phase, .idle)

        let firstAxis = state.resolveGestureAxis(
            translation: CGSize(width: 4, height: 20)
        )
        let lockedAxis = state.resolveGestureAxis(
            translation: CGSize(width: 100, height: 1)
        )

        XCTAssertEqual(firstAxis, .vertical)
        XCTAssertEqual(lockedAxis, .vertical)
        XCTAssertEqual(state.renderTargetProgress, 0)
        XCTAssertEqual(state.phase, .idle)
    }

    func testOpenAndClosedHitRegionsDoNotCoverContentOrDetail() {
        XCTAssertFalse(FloatingSidebarGestureHitRegion.acceptsOpenSurface(
            start: CGPoint(x: 265, y: 200),
            surfaceSize: CGSize(width: 300, height: 800),
            dragStripWidth: 22,
            verticalInset: 72,
            trailingInset: 12
        ))
        XCTAssertTrue(FloatingSidebarGestureHitRegion.acceptsOpenSurface(
            start: CGPoint(x: 266, y: 200),
            surfaceSize: CGSize(width: 300, height: 800),
            dragStripWidth: 22,
            verticalInset: 72,
            trailingInset: 12
        ))
        XCTAssertTrue(FloatingSidebarGestureHitRegion.acceptsOpenSurface(
            start: CGPoint(x: 288, y: 200),
            surfaceSize: CGSize(width: 300, height: 800),
            dragStripWidth: 22,
            verticalInset: 72,
            trailingInset: 12
        ))
        XCTAssertFalse(FloatingSidebarGestureHitRegion.acceptsOpenSurface(
            start: CGPoint(x: 289, y: 200),
            surfaceSize: CGSize(width: 300, height: 800),
            dragStripWidth: 22,
            verticalInset: 72,
            trailingInset: 12
        ))
        XCTAssertFalse(FloatingSidebarGestureHitRegion.acceptsOpenSurface(
            start: CGPoint(x: 277, y: 50),
            surfaceSize: CGSize(width: 300, height: 800),
            dragStripWidth: 22,
            verticalInset: 72,
            trailingInset: 12
        ))
        XCTAssertFalse(FloatingSidebarGestureHitRegion.acceptsOpenSurface(
            start: CGPoint(x: 277, y: 750),
            surfaceSize: CGSize(width: 300, height: 800),
            dragStripWidth: 22,
            verticalInset: 72,
            trailingInset: 12
        ))

        let closedContainer = CGSize(width: 1_024, height: 800)
        let closedFrame = FloatingSidebarGestureHitRegion.closedEdgeFrame(
            containerSize: closedContainer,
            edgeWidth: 22,
            verticalInset: 72
        )
        XCTAssertEqual(closedFrame, CGRect(x: 0, y: 72, width: 22, height: 656))
        XCTAssertFalse(FloatingSidebarGestureHitRegion.acceptsClosedEdge(
            start: CGPoint(x: 11, y: 71.9),
            containerSize: closedContainer,
            edgeWidth: 22,
            verticalInset: 72
        ))
        XCTAssertTrue(FloatingSidebarGestureHitRegion.acceptsClosedEdge(
            start: CGPoint(x: 11, y: 400),
            containerSize: closedContainer,
            edgeWidth: 22,
            verticalInset: 72
        ))
        XCTAssertFalse(FloatingSidebarGestureHitRegion.acceptsClosedEdge(
            start: CGPoint(x: 11, y: 728.1),
            containerSize: closedContainer,
            edgeWidth: 22,
            verticalInset: 72
        ))
        XCTAssertFalse(FloatingSidebarGestureHitRegion.acceptsClosedEdge(
            start: CGPoint(x: 23, y: 400),
            containerSize: closedContainer,
            edgeWidth: 22,
            verticalInset: 72
        ))
    }

    func testRubberBandIsContinuousAndResistsOvershoot() {
        XCTAssertEqual(
            FloatingSidebarProjection.rubberBandedProgress(0, sidebarWidth: 300),
            0
        )
        XCTAssertEqual(
            FloatingSidebarProjection.rubberBandedProgress(1, sidebarWidth: 300),
            1
        )

        let below = FloatingSidebarProjection.rubberBandedProgress(-0.2, sidebarWidth: 300)
        let above = FloatingSidebarProjection.rubberBandedProgress(1.2, sidebarWidth: 300)
        XCTAssertGreaterThan(below, -0.2)
        XCTAssertLessThan(below, 0)
        XCTAssertGreaterThan(above, 1)
        XCTAssertLessThan(above, 1.2)
        XCTAssertEqual(FloatingSidebarProjection.clampedLayoutProgress(below), 0)
        XCTAssertEqual(FloatingSidebarProjection.clampedLayoutProgress(above), 1)
    }

    func testSlowReleaseUsesPredictedLanding() {
        let opens = FloatingSidebarProjection.releaseDecision(
            baseProgress: 0.2,
            translation: 15,
            predictedEndTranslation: 210,
            velocity: 100,
            sidebarWidth: 300
        )
        let closes = FloatingSidebarProjection.releaseDecision(
            baseProgress: 0.8,
            translation: -15,
            predictedEndTranslation: -210,
            velocity: -100,
            sidebarWidth: 300
        )

        XCTAssertEqual(opens.target, .open)
        XCTAssertEqual(closes.target, .closed)
    }

    func testFastReleaseUsesVelocitySignAndClampsEnergy() {
        let opens = FloatingSidebarProjection.releaseDecision(
            baseProgress: 0.05,
            translation: 0,
            predictedEndTranslation: 0,
            velocity: 10_000,
            sidebarWidth: 300
        )
        let closes = FloatingSidebarProjection.releaseDecision(
            baseProgress: 0.95,
            translation: 0,
            predictedEndTranslation: 0,
            velocity: -10_000,
            sidebarWidth: 300
        )

        XCTAssertEqual(opens.target, .open)
        XCTAssertEqual(opens.progressVelocity, 4)
        XCTAssertLessThanOrEqual(opens.projectedLanding, 1.25)
        XCTAssertEqual(closes.target, .closed)
        XCTAssertEqual(closes.progressVelocity, -4)
        XCTAssertGreaterThanOrEqual(closes.projectedLanding, -0.25)
    }

    func testSpringInitialVelocityUsesRemainingPresentationDistance() {
        let closing = FloatingSidebarProjection.springInitialVelocity(
            progressVelocity: -2,
            currentPresentationProgress: 0.8,
            targetProgress: 0
        )
        let opening = FloatingSidebarProjection.springInitialVelocity(
            progressVelocity: 2,
            currentPresentationProgress: 0.2,
            targetProgress: 1
        )
        let closingAwayFromTarget = FloatingSidebarProjection.springInitialVelocity(
            progressVelocity: 1,
            currentPresentationProgress: 0.8,
            targetProgress: 0
        )
        let overEdgeTowardTarget = FloatingSidebarProjection.springInitialVelocity(
            progressVelocity: -1,
            currentPresentationProgress: 1.1,
            targetProgress: 1
        )
        let overEdgeAwayFromTarget = FloatingSidebarProjection.springInitialVelocity(
            progressVelocity: 1,
            currentPresentationProgress: 1.1,
            targetProgress: 1
        )

        XCTAssertEqual(closing, 2.5, accuracy: 0.0001)
        XCTAssertEqual(opening, 2.5, accuracy: 0.0001)
        XCTAssertEqual(closingAwayFromTarget, -1.25, accuracy: 0.0001)
        XCTAssertEqual(overEdgeTowardTarget, 10, accuracy: 0.0001)
        XCTAssertEqual(overEdgeAwayFromTarget, -10, accuracy: 0.0001)
    }

    func testSpringInitialVelocityIsFiniteAtShortOrInvalidDistances() {
        let shortDistance = FloatingSidebarProjection.springInitialVelocity(
            progressVelocity: 4,
            currentPresentationProgress: 0.9995,
            targetProgress: 1
        )

        XCTAssertTrue(shortDistance.isFinite)
        XCTAssertEqual(
            shortDistance,
            FloatingSidebarProjection.maximumSpringInitialVelocity,
            accuracy: 0.0001
        )
        XCTAssertEqual(FloatingSidebarProjection.springInitialVelocity(
            progressVelocity: 4,
            currentPresentationProgress: 1,
            targetProgress: 1
        ), 0)
        XCTAssertEqual(FloatingSidebarProjection.springInitialVelocity(
            progressVelocity: .infinity,
            currentPresentationProgress: 0.5,
            targetProgress: 1
        ), 0)
        XCTAssertEqual(FloatingSidebarProjection.springInitialVelocity(
            progressVelocity: 1,
            currentPresentationProgress: .nan,
            targetProgress: 1
        ), 0)
    }

    func testAnimatableModifierSynchronouslyCachesRenderedProgress() {
        let tracker = FloatingSidebarRenderedProgressTracker(initialValue: 1)
        var modifier = FloatingSidebarProgressModifier(progress: 1, tracker: tracker)

        modifier.animatableData = 0.42

        XCTAssertEqual(tracker.value, 0.42, accuracy: 0.0001)
        XCTAssertEqual(modifier.progress, 0.42, accuracy: 0.0001)
    }

    func testReverseTakeoverStartsAtRenderedProgressAndFencesOldCompletion() {
        let tracker = FloatingSidebarRenderedProgressTracker(initialValue: 1)
        var state = FloatingSidebarPresentationState()
        let closing = state.prepareSettling(target: .closed, springInitialVelocity: -2)
        state.startSettling(closing)

        tracker.record(0.42)
        state.beginInteraction(
            renderedProgress: tracker.value,
            consumedHysteresisTranslation: -10
        )

        XCTAssertEqual(state.renderTargetProgress, 0.42, accuracy: 0.0001)
        state.updateInteraction(translation: -12, sidebarWidth: 300)

        XCTAssertEqual(state.renderTargetProgress, 0.42 - 2.0 / 300.0, accuracy: 0.0001)
        XCTAssertFalse(state.completeSettling(revision: closing.revision))
        guard case .interaction(let interaction) = state.phase else {
            return XCTFail("接管后必须由 interaction 独占 progress")
        }
        XCTAssertEqual(interaction.baseProgress, 0.42, accuracy: 0.0001)
    }

    func testOpeningReverseTakeoverAlsoStartsAtRenderedProgress() {
        let tracker = FloatingSidebarRenderedProgressTracker(initialValue: 0)
        var state = FloatingSidebarPresentationState()
        state.restore(.closed)
        let opening = state.prepareSettling(target: .open, springInitialVelocity: 2)
        state.startSettling(opening)

        tracker.record(0.58)
        state.beginInteraction(
            renderedProgress: tracker.value,
            consumedHysteresisTranslation: 10
        )

        XCTAssertEqual(state.renderTargetProgress, 0.58, accuracy: 0.0001)
        state.updateInteraction(translation: 12, sidebarWidth: 300)

        XCTAssertEqual(state.renderTargetProgress, 0.58 + 2.0 / 300.0, accuracy: 0.0001)
        XCTAssertFalse(state.completeSettling(revision: opening.revision))
        guard case .interaction(let interaction) = state.phase else {
            return XCTFail("反向接管 opening 后必须由 interaction 独占 progress")
        }
        XCTAssertEqual(interaction.baseProgress, 0.58, accuracy: 0.0001)
    }

    func testButtonOrKeyboardCommitRejectsOldSettlingCompletion() {
        var state = FloatingSidebarPresentationState()
        let closing = state.prepareSettling(target: .closed, springInitialVelocity: -1)
        state.startSettling(closing)
        // 按钮和 Control-Command-S 都按 committed visibility 调用同一 settling 入口。
        let opening = state.prepareSettling(
            target: state.committedVisibility.toggled,
            springInitialVelocity: 1
        )
        state.startSettling(opening)

        XCTAssertFalse(state.completeSettling(revision: closing.revision))
        XCTAssertTrue(state.completeSettling(revision: opening.revision))
        XCTAssertEqual(state.committedVisibility, .open)
        XCTAssertEqual(state.renderTargetProgress, 1)
        XCTAssertEqual(state.phase, .idle)
    }

    func testNormalizedInteractionSurvivesSidebarWidthChanges() {
        var narrow = FloatingSidebarPresentationState()
        narrow.beginInteraction(renderedProgress: 0.5, consumedHysteresisTranslation: 10)
        narrow.updateInteraction(translation: 40, sidebarWidth: 300)

        var wide = FloatingSidebarPresentationState()
        wide.beginInteraction(renderedProgress: 0.5, consumedHysteresisTranslation: 10)
        wide.updateInteraction(translation: 70, sidebarWidth: 600)

        XCTAssertEqual(narrow.renderTargetProgress, 0.6, accuracy: 0.0001)
        XCTAssertEqual(wide.renderTargetProgress, 0.6, accuracy: 0.0001)
    }

    func testCoalescedFirstHorizontalEventOnlyConsumesDirectionHysteresis() {
        let firstTranslation: CGFloat = -278
        let consumed = FloatingSidebarGestureArbitration.consumedHysteresisTranslation(
            for: firstTranslation
        )
        var state = FloatingSidebarPresentationState()
        state.beginInteraction(
            renderedProgress: 1,
            consumedHysteresisTranslation: consumed
        )
        state.updateInteraction(translation: firstTranslation, sidebarWidth: 300)
        let decision = state.releaseDecision(
            translation: firstTranslation,
            predictedEndTranslation: -300,
            velocity: -500,
            sidebarWidth: 300
        )

        XCTAssertEqual(consumed, -10)
        XCTAssertEqual(state.renderTargetProgress, 1 - 268.0 / 300.0, accuracy: 0.0001)
        XCTAssertEqual(decision?.target, .closed)
    }

    func testClosedEdgeRecognizerSurvivesInteractionUntilRelease() {
        var state = FloatingSidebarPresentationState()
        state.restore(.closed)

        XCTAssertTrue(state.keepsClosedEdgeInteractive)
        state.beginInteraction(
            renderedProgress: 0,
            consumedHysteresisTranslation: 10
        )
        XCTAssertTrue(state.keepsClosedEdgeInteractive)

        let opening = state.prepareSettling(target: .open, springInitialVelocity: 1)
        state.startSettling(opening)
        XCTAssertFalse(state.keepsClosedEdgeInteractive)
    }

    func testRestoreReturnsToCommittedIdleState() {
        var state = FloatingSidebarPresentationState()

        state.restore(.closed)

        XCTAssertEqual(state.committedVisibility, .closed)
        XCTAssertEqual(state.renderTargetProgress, 0)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.isIdleClosed)
    }
}
