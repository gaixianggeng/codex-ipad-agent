import SwiftUI

struct ConversationLayout: Equatable {
    // 只有拿不到系统 size class（例如部分预览宿主）时才按宽度兜底；真实设备优先按
    // compact/regular 区分手机与 iPad，避免 iPad mini 竖屏误入多级系统菜单。
    static let compactComposerFallbackMaximumWidth: CGFloat = 560

    let horizontalInset: CGFloat
    let messageSideSpacer: CGFloat
    let composerAvailableWidth: CGFloat
    let composerMaxWidth: CGFloat
    let composerTopPadding: CGFloat
    let composerBottomPadding: CGFloat
    let userBubbleMaxWidth: CGFloat
    let assistantBubbleMaxWidth: CGFloat
    let systemMaxWidth: CGFloat
    let runtimeCardMaxWidth: CGFloat
    let emptyStateMaxWidth: CGFloat

    var messageRowInsets: EdgeInsets {
        EdgeInsets(top: 8, leading: horizontalInset, bottom: 8, trailing: horizontalInset)
    }

    static func usesCompactComposerToolbar(
        availableWidth: CGFloat?,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        if let horizontalSizeClass {
            return horizontalSizeClass == .compact
        }
        return availableWidth.map { $0 < compactComposerFallbackMaximumWidth } ?? false
    }

    init(
        containerWidth: CGFloat,
        horizontalSizeClass: UserInterfaceSizeClass?,
        safeAreaInsets: EdgeInsets = EdgeInsets()
    ) {
        // NavigationSplitView 的 detail 在 iPad 横屏下可能仍收到整窗宽度提案，侧栏宽度则体现在
        // leading safe area 中。所有会话轨道必须按真实可见宽度计算，否则 composer 会伸到屏幕外。
        let visibleContainerWidth = max(
            0,
            containerWidth - safeAreaInsets.leading - safeAreaInsets.trailing
        )
        let isCompactWidth = horizontalSizeClass == .compact || visibleContainerWidth < 560
        let isWideCompact = horizontalSizeClass == .compact && visibleContainerWidth >= 600
        let isVeryCompactWidth = visibleContainerWidth < 360
        let isTightPadWidth = visibleContainerWidth < 820

        // 与会话库 20pt 的卡片轨道接近，同时给 320/344pt 极窄屏保留必要内容宽度。
        horizontalInset = isCompactWidth ? (isVeryCompactWidth ? 12 : 16) : (isTightPadWidth ? 16 : 24)
        messageSideSpacer = isCompactWidth ? 12 : (isTightPadWidth ? 24 : 56)
        composerAvailableWidth = max(240, visibleContainerWidth - horizontalInset * 2)
        // iPhone 横屏仍然是 compact size class，但不应该把输入卡拉满整条长边。
        // 居中的宽度上限同时缩短正文行长，并给系统返回手势留出清晰的边缘空间。
        composerMaxWidth = isWideCompact
            ? min(680, composerAvailableWidth)
            : (isCompactWidth ? .infinity : min(940, max(360, composerAvailableWidth)))
        composerTopPadding = isCompactWidth ? 10 : 12
        // safeAreaInset 已经负责系统手势区；这里只保留卡片与安全区之间的轻量呼吸感，
        // 避免两层底距叠加后让输入卡看起来悬得过高。
        composerBottomPadding = isCompactWidth ? 8 : 10

        // 气泡宽度按实际容器收缩，保留左右身份感，同时避免 iPhone/mini 竖屏横向溢出。
        let rowAvailableWidth = max(240, visibleContainerWidth - horizontalInset * 2 - messageSideSpacer)
        userBubbleMaxWidth = min(isCompactWidth ? 420 : 560, rowAvailableWidth)
        let assistantWidthCap: CGFloat = isWideCompact ? 660 : (isCompactWidth ? 520 : (isTightPadWidth ? 700 : 760))
        assistantBubbleMaxWidth = min(assistantWidthCap, rowAvailableWidth)
        systemMaxWidth = min(520, max(240, visibleContainerWidth - horizontalInset * 2))
        runtimeCardMaxWidth = min(560, max(260, visibleContainerWidth - horizontalInset * 2))
        emptyStateMaxWidth = min(420, max(260, visibleContainerWidth - horizontalInset * 2))
    }
}
