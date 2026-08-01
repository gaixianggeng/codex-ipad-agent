import Foundation
import SwiftUI

enum FloatingSidebarVisibility: CGFloat, Equatable {
    case closed = 0
    case open = 1

    var progress: CGFloat { rawValue }

    var toggled: FloatingSidebarVisibility {
        self == .open ? .closed : .open
    }
}

enum FloatingSidebarGestureAxis: Equatable {
    case pending
    case horizontal
    case vertical
}

struct FloatingSidebarSettling: Equatable {
    let target: FloatingSidebarVisibility
    let revision: UInt
    let initialVelocity: CGFloat
}

struct FloatingSidebarInteraction: Equatable {
    let baseProgress: CGFloat
    let consumedHysteresisTranslation: CGFloat
}

/// 浮动侧栏只有一个阶段能拥有视觉目标：idle、interaction、settling 三者互斥。
/// committedVisibility 表示最终语义，renderTargetProgress 只表示当前阶段交给渲染层的目标。
struct FloatingSidebarPresentationState: Equatable {
    enum Phase: Equatable {
        case idle
        case interaction(FloatingSidebarInteraction)
        case settling(FloatingSidebarSettling)
    }

    private(set) var committedVisibility: FloatingSidebarVisibility = .open
    private(set) var renderTargetProgress: CGFloat = FloatingSidebarVisibility.open.progress
    private(set) var phase: Phase = .idle
    private(set) var gestureAxis: FloatingSidebarGestureAxis = .pending
    private(set) var revision: UInt = 0

    var isIdleClosed: Bool {
        phase == .idle && committedVisibility == .closed
    }

    var keepsOpenSurfaceInteractive: Bool {
        phase != .idle || committedVisibility == .open
    }

    var keepsClosedEdgeInteractive: Bool {
        guard committedVisibility == .closed else { return false }
        // 从 closed 开始拖动后必须保留原命中层直到 onEnded；否则首个 onChanged
        // 切到 interaction 就会移除 recognizer，后续位移与释放事件一起丢失。
        switch phase {
        case .idle, .interaction:
            return true
        case .settling:
            return false
        }
    }

    var isInteracting: Bool {
        if case .interaction = phase {
            return true
        }
        return false
    }

    mutating func restore(_ visibility: FloatingSidebarVisibility) {
        revision &+= 1
        committedVisibility = visibility
        renderTargetProgress = visibility.progress
        phase = .idle
        gestureAxis = .pending
    }

    mutating func resolveGestureAxis(translation: CGSize) -> FloatingSidebarGestureAxis {
        gestureAxis = FloatingSidebarGestureArbitration.resolve(
            current: gestureAxis,
            translation: translation
        )
        return gestureAxis
    }

    mutating func beginInteraction(
        renderedProgress: CGFloat,
        consumedHysteresisTranslation: CGFloat
    ) {
        // 必须先由调用方读取 tracker，再进入 interaction；否则会读取到新的逻辑目标。
        revision &+= 1
        let progress = FloatingSidebarProjection.clampRenderedProgress(renderedProgress)
        renderTargetProgress = progress
        phase = .interaction(
            FloatingSidebarInteraction(
                baseProgress: progress,
                consumedHysteresisTranslation: consumedHysteresisTranslation
            )
        )
    }

    @discardableResult
    mutating func updateInteraction(
        translation: CGFloat,
        sidebarWidth: CGFloat
    ) -> CGFloat? {
        guard case .interaction(let interaction) = phase,
              sidebarWidth > 0 else {
            return nil
        }

        let effectiveTranslation = translation - interaction.consumedHysteresisTranslation
        let rawProgress = interaction.baseProgress + effectiveTranslation / sidebarWidth
        let renderedProgress = FloatingSidebarProjection.rubberBandedProgress(
            rawProgress,
            sidebarWidth: sidebarWidth
        )
        renderTargetProgress = renderedProgress
        return renderedProgress
    }

    mutating func releaseDecision(
        translation: CGFloat,
        predictedEndTranslation: CGFloat,
        velocity: CGFloat,
        sidebarWidth: CGFloat
    ) -> FloatingSidebarReleaseDecision? {
        guard case .interaction(let interaction) = phase else {
            resetGesture()
            return nil
        }

        let decision = FloatingSidebarProjection.releaseDecision(
            baseProgress: interaction.baseProgress,
            translation: translation - interaction.consumedHysteresisTranslation,
            predictedEndTranslation: predictedEndTranslation - interaction.consumedHysteresisTranslation,
            velocity: velocity,
            sidebarWidth: sidebarWidth
        )
        resetGesture()
        return decision
    }

    mutating func prepareSettling(
        target: FloatingSidebarVisibility,
        initialVelocity: CGFloat
    ) -> FloatingSidebarSettling {
        revision &+= 1
        return FloatingSidebarSettling(
            target: target,
            revision: revision,
            initialVelocity: FloatingSidebarProjection.clampInitialVelocity(initialVelocity)
        )
    }

    mutating func startSettling(_ settling: FloatingSidebarSettling) {
        guard revision == settling.revision else { return }
        committedVisibility = settling.target
        renderTargetProgress = settling.target.progress
        phase = .settling(settling)
        gestureAxis = .pending
    }

    @discardableResult
    mutating func completeSettling(revision expectedRevision: UInt) -> Bool {
        guard revision == expectedRevision,
              case .settling(let settling) = phase,
              settling.revision == expectedRevision else {
            return false
        }
        renderTargetProgress = settling.target.progress
        phase = .idle
        gestureAxis = .pending
        return true
    }

    mutating func resetGesture() {
        gestureAxis = .pending
    }
}

enum FloatingSidebarGestureArbitration {
    static let minimumDistance: CGFloat = 10
    static let horizontalDominanceRatio: CGFloat = 1.15

    static func consumedHysteresisTranslation(for horizontalTranslation: CGFloat) -> CGFloat {
        guard horizontalTranslation != 0 else { return 0 }
        // 方向锁只消费 minimumDistance；不能吞掉系统合并进首个 onChanged 的整段位移。
        return horizontalTranslation.sign == .minus
            ? -min(abs(horizontalTranslation), minimumDistance)
            : min(abs(horizontalTranslation), minimumDistance)
    }

    static func resolve(
        current: FloatingSidebarGestureAxis,
        translation: CGSize
    ) -> FloatingSidebarGestureAxis {
        guard current == .pending else { return current }

        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        guard max(horizontal, vertical) >= minimumDistance else {
            return .pending
        }

        // 只让明确横向的轨迹接管侧栏；其余轨迹一次性让给 List 的纵向滚动。
        return horizontal > vertical * horizontalDominanceRatio
            ? .horizontal
            : .vertical
    }
}

enum FloatingSidebarGestureHitRegion {
    static func acceptsOpenSurface(
        start: CGPoint,
        surfaceSize: CGSize,
        dragStripWidth: CGFloat,
        verticalInset: CGFloat,
        trailingInset: CGFloat
    ) -> Bool {
        guard surfaceSize.width > 0,
              surfaceSize.height > verticalInset * 2,
              dragStripWidth > 0,
              trailingInset >= 0,
              dragStripWidth + trailingInset <= surfaceSize.width else {
            return false
        }
        return start.x >= surfaceSize.width - trailingInset - dragStripWidth
            && start.x <= surfaceSize.width - trailingInset
            && start.y >= verticalInset
            && start.y <= surfaceSize.height - verticalInset
    }

    static func acceptsClosedEdge(startX: CGFloat, edgeWidth: CGFloat) -> Bool {
        guard edgeWidth > 0 else { return false }
        return startX >= 0 && startX <= edgeWidth
    }
}

struct FloatingSidebarReleaseDecision: Equatable {
    let target: FloatingSidebarVisibility
    let projectedLanding: CGFloat
    let initialVelocity: CGFloat
}

enum FloatingSidebarProjection {
    static let rubberBandConstant: CGFloat = 0.55
    static let highVelocityThreshold: CGFloat = 700
    static let minimumProjectedLanding: CGFloat = -0.25
    static let maximumProjectedLanding: CGFloat = 1.25
    static let maximumInitialVelocity: CGFloat = 4
    static let decelerationRate: CGFloat = 0.99

    static func clampedLayoutProgress(_ progress: CGFloat) -> CGFloat {
        min(max(progress, 0), 1)
    }

    static func clampRenderedProgress(_ progress: CGFloat) -> CGFloat {
        min(max(progress, minimumProjectedLanding), maximumProjectedLanding)
    }

    static func clampInitialVelocity(_ velocity: CGFloat) -> CGFloat {
        min(max(velocity, -maximumInitialVelocity), maximumInitialVelocity)
    }

    static func rubberBandedProgress(
        _ rawProgress: CGFloat,
        sidebarWidth: CGFloat
    ) -> CGFloat {
        guard sidebarWidth > 0 else { return clampedLayoutProgress(rawProgress) }
        if rawProgress < 0 {
            let overshoot = -rawProgress * sidebarWidth
            return -rubberBandDistance(overshoot, dimension: sidebarWidth) / sidebarWidth
        }
        if rawProgress > 1 {
            let overshoot = (rawProgress - 1) * sidebarWidth
            return 1 + rubberBandDistance(overshoot, dimension: sidebarWidth) / sidebarWidth
        }
        return rawProgress
    }

    static func releaseDecision(
        baseProgress: CGFloat,
        translation: CGFloat,
        predictedEndTranslation: CGFloat,
        velocity: CGFloat,
        sidebarWidth: CGFloat
    ) -> FloatingSidebarReleaseDecision {
        guard sidebarWidth > 0 else {
            let target: FloatingSidebarVisibility = baseProgress >= 0.5 ? .open : .closed
            return FloatingSidebarReleaseDecision(
                target: target,
                projectedLanding: target.progress,
                initialVelocity: 0
            )
        }

        let currentProgress = baseProgress + translation / sidebarWidth
        let predictedProgress = baseProgress + predictedEndTranslation / sidebarWidth
        let normalizedVelocity = clampInitialVelocity(velocity / sidebarWidth)
        let velocityProjection = projectedDistance(velocity: velocity) / sidebarWidth
        let projectedByVelocity = currentProgress + velocityProjection

        // predictedEnd 与指数衰减投影都限定在有限区间，异常触控速度不能制造无限远落点。
        let landing = min(
            max(
                currentProgress * 0.35
                    + predictedProgress * 0.4
                    + projectedByVelocity * 0.25,
                minimumProjectedLanding
            ),
            maximumProjectedLanding
        )

        let target: FloatingSidebarVisibility
        if abs(velocity) >= highVelocityThreshold {
            target = velocity > 0 ? .open : .closed
        } else {
            target = landing >= 0.5 ? .open : .closed
        }

        return FloatingSidebarReleaseDecision(
            target: target,
            projectedLanding: landing,
            initialVelocity: normalizedVelocity
        )
    }

    private static func rubberBandDistance(_ distance: CGFloat, dimension: CGFloat) -> CGFloat {
        (distance * dimension * rubberBandConstant)
            / (dimension + rubberBandConstant * abs(distance))
    }

    private static func projectedDistance(velocity: CGFloat) -> CGFloat {
        (velocity / 1_000) * decelerationRate / (1 - decelerationRate)
    }
}

/// AnimatableModifier 每帧同步写入；它不是 ObservableObject，也绝不反向驱动 View。
/// 手势开始只读取当前值，从而从真实的 animatableData 接管，而不是从逻辑 target 接管。
final class FloatingSidebarRenderedProgressTracker {
    private let lock = NSLock()
    private var storage: CGFloat

    init(initialValue: CGFloat) {
        storage = initialValue
    }

    var value: CGFloat {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ value: CGFloat) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private struct FloatingSidebarPresentationProgressKey: EnvironmentKey {
    static let defaultValue: CGFloat = FloatingSidebarVisibility.open.progress
}

extension EnvironmentValues {
    fileprivate var floatingSidebarPresentationProgress: CGFloat {
        get { self[FloatingSidebarPresentationProgressKey.self] }
        set { self[FloatingSidebarPresentationProgressKey.self] = newValue }
    }
}

struct FloatingSidebarProgressModifier: AnimatableModifier {
    var progress: CGFloat
    let tracker: FloatingSidebarRenderedProgressTracker

    var animatableData: CGFloat {
        get { progress }
        set {
            progress = newValue
            // 同一个插值值既进入视觉环境，也同步留给下一次手势接管。
            tracker.record(newValue)
        }
    }

    func body(content: Content) -> some View {
        content.environment(\.floatingSidebarPresentationProgress, progress)
    }
}

struct FloatingSidebarAnimatedScene<Detail: View, Sidebar: View>: View {
    @Environment(\.floatingSidebarPresentationProgress) private var progress

    let sidebarWidth: CGFloat
    private let detail: Detail
    private let sidebar: Sidebar

    init(
        sidebarWidth: CGFloat,
        @ViewBuilder detail: () -> Detail,
        @ViewBuilder sidebar: () -> Sidebar
    ) {
        self.sidebarWidth = sidebarWidth
        self.detail = detail()
        self.sidebar = sidebar()
    }

    var body: some View {
        let layoutProgress = FloatingSidebarProjection.clampedLayoutProgress(progress)

        ZStack(alignment: .leading) {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, layoutProgress * sidebarWidth)

            sidebar
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity)
                .offset(x: (progress - 1) * sidebarWidth)
                .zIndex(1)
        }
    }
}
