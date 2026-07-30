import SwiftUI

// 工作台通用导航外观与布局组件集中在此，保持各页面结构稳定。
extension View {
    func themedWorkbenchNavigationChrome(tokens: ThemeTokens, colorScheme: ColorScheme) -> some View {
        // 会话工作台嵌在 NavigationSplitView 里，系统导航栏默认会透出平台背景。
        // 这里统一让导航栏和状态栏区域吃主题色，避免 iPad 横屏顶部出现黑色断层。
        toolbarBackground(tokens.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(colorScheme, for: .navigationBar)
    }
}

extension ConnectionStatus {
    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

struct WorkbenchLayout: Equatable {
    struct ColumnWidth: Equatable {
        let min: CGFloat
        let ideal: CGFloat
        let max: CGFloat
    }

    let projectColumn: ColumnWidth
    let inspectorColumn: ColumnWidth
    let titleMaxWidth: CGFloat
    let usesCompactNavigation: Bool
    let prefersDetailOnly: Bool
    let usesAttachedInspector: Bool

    init(containerWidth: CGFloat, horizontalSizeClass: UserInterfaceSizeClass?) {
        let usesCompactMetrics = horizontalSizeClass == .compact || containerWidth < 760
        // 768pt 的旧款 iPad mini 竖屏仍是 regular size class，但双栏会自动退成 detail-only。
        // 这类宽度也必须使用真正的 push 导航，否则系统不会提供返回按钮和左缘返回手势。
        let needsCompactNavigation = horizontalSizeClass == .compact || containerWidth < 860
        let isTightPadWidth = containerWidth < 980

        if usesCompactMetrics {
            projectColumn = ColumnWidth(min: 220, ideal: 260, max: 300)
            // 手机端维护动作已经收进单一菜单，标题可以获得接近 Claude 的两行阅读宽度。
            titleMaxWidth = max(160, min(230, containerWidth - 160))
        } else if isTightPadWidth {
            projectColumn = ColumnWidth(min: 240, ideal: 280, max: 320)
            titleMaxWidth = 240
        } else {
            projectColumn = ColumnWidth(min: 280, ideal: 330, max: 380)
            titleMaxWidth = 340
        }

        inspectorColumn = containerWidth < 1280
            ? ColumnWidth(min: 280, ideal: 300, max: 320)
            : ColumnWidth(min: 300, ideal: 340, max: 380)

        // 三栏只在真正宽的横向空间里附着；窄窗口改用 sheet，保住会话阅读/输入区域。
        usesAttachedInspector = horizontalSizeClass != .compact && containerWidth >= 1180
        usesCompactNavigation = needsCompactNavigation
        prefersDetailOnly = needsCompactNavigation
    }
}

extension View {
    func sessionInspectorPresentation(isPresented: Binding<Bool>, layout: WorkbenchLayout) -> some View {
        modifier(SessionInspectorPresentation(isPresented: isPresented, layout: layout))
    }
}

struct SessionInspectorPresentation: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var isPresented: Bool
    let layout: WorkbenchLayout

    @ViewBuilder
    func body(content: Content) -> some View {
        if layout.usesAttachedInspector {
            content.inspector(isPresented: $isPresented) {
                SessionInspectorView()
                    .inspectorColumnWidth(
                        min: layout.inspectorColumn.min,
                        ideal: layout.inspectorColumn.ideal,
                        max: layout.inspectorColumn.max
                    )
            }
        } else {
            content.sheet(isPresented: $isPresented) {
                NavigationStack {
                    SessionInspectorView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(L10n.text("ui.complete")) {
                                    isPresented = false
                                }
                            }
                        }
                }
                .presentationDetents(horizontalSizeClass == .compact ? [.large] : [.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

struct WorkbenchPageHeader: View {
    @EnvironmentObject private var themeStore: ThemeStore
    let title: String
    let subtitle: String
    let tokens: ThemeTokens

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(themeStore.uiFont(.title2, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
            Text(subtitle)
                .font(themeStore.uiFont(.callout))
                .foregroundStyle(tokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum WorkbenchPageLayout {
    static let maxContentWidth: CGFloat = 820
    static let regularPadding: CGFloat = 24
    static let compactPadding: CGFloat = 20
    static let compactBottomPadding: CGFloat = 132
}

struct StatusPill: View {
    enum Kind {
        case success
        case warning
        case neutral
    }

    let text: String
    let kind: Kind
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Text(text)
            .font(themeStore.uiFont(size: 12, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.86)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background(tokens: tokens))
            .foregroundStyle(foreground(tokens: tokens))
            .clipShape(Capsule())
    }

    private func background(tokens: ThemeTokens) -> Color {
        switch kind {
        case .success:
            return tokens.success.opacity(0.16)
        case .warning:
            return tokens.warning.opacity(0.18)
        case .neutral:
            return tokens.elevatedSurface
        }
    }

    private func foreground(tokens: ThemeTokens) -> Color {
        switch kind {
        case .success:
            return tokens.success
        case .warning:
            return tokens.warning
        case .neutral:
            return tokens.secondaryText
        }
    }
}

/// 设置页和工作台侧栏共用的额度窗口模型。集中选择规则后，两个入口不会因为
/// 服务端 primary / secondary 槽位变化而展示不同的三个圆环。
struct CombinedUsageItem: Identifiable {
    let runtimeProvider: String
    let providerName: String
    let window: CodexUsageWindowDisplay
    let tint: Color

    var id: String {
        "\(runtimeProvider):\(window.id)"
    }

    static func make(
        codexDisplay: CodexUsageWindowsDisplay,
        claudeDisplay: CodexUsageWindowsDisplay,
        includesClaude: Bool,
        // 三环由外到内依次是 Codex 长窗口、Claude 长窗口、Claude 短窗口。
        // 外环使用青色、中环使用粉色；设置页与左上角入口复用这里，避免图例和圆环错位。
        codexTint: Color = .cyan,
        claudeLongTint: Color = .pink,
        claudeShortTint: Color
    ) -> [CombinedUsageItem] {
        var items: [CombinedUsageItem] = []

        if let codexWindow = preferredLongWindow(in: codexDisplay) {
            items.append(
                CombinedUsageItem(
                    runtimeProvider: "codex",
                    providerName: providerName(for: codexDisplay, fallback: "Codex"),
                    window: codexWindow,
                    tint: codexTint
                )
            )
        }

        if includesClaude, let claudeLongWindow = preferredLongWindow(in: claudeDisplay) {
            items.append(
                CombinedUsageItem(
                    runtimeProvider: "claude",
                    providerName: providerName(for: claudeDisplay, fallback: "Claude"),
                    window: claudeLongWindow,
                    tint: claudeLongTint
                )
            )

            if let claudeShortWindow = preferredShortWindow(
                in: claudeDisplay,
                excluding: claudeLongWindow
            ) {
                items.append(
                    CombinedUsageItem(
                        runtimeProvider: "claude",
                        providerName: providerName(for: claudeDisplay, fallback: "Claude"),
                        window: claudeShortWindow,
                        tint: claudeShortTint
                    )
                )
            }
        }

        return Array(items.prefix(3))
    }

    private static func preferredLongWindow(
        in display: CodexUsageWindowsDisplay
    ) -> CodexUsageWindowDisplay? {
        let dayScaleWindows = display.windows.filter(\.isDayScaleWindow)
        return dayScaleWindows.max(by: durationAscending)
            ?? display.windows.max(by: durationAscending)
    }

    private static func preferredShortWindow(
        in display: CodexUsageWindowsDisplay,
        excluding longWindow: CodexUsageWindowDisplay
    ) -> CodexUsageWindowDisplay? {
        display.windows
            .filter { $0.id != longWindow.id }
            .min(by: durationAscending)
    }

    private static func durationAscending(
        _ lhs: CodexUsageWindowDisplay,
        _ rhs: CodexUsageWindowDisplay
    ) -> Bool {
        (lhs.durationMinutes ?? -1) < (rhs.durationMinutes ?? -1)
    }

    /// 已知产品名统一品牌大小写；协议原值仍保留在 runtimeProvider 中。
    private static func providerName(
        for display: CodexUsageWindowsDisplay,
        fallback: String
    ) -> String {
        switch display.displayName.lowercased() {
        case "codex":
            return "Codex"
        case "claude":
            return "Claude"
        default:
            return display.displayName.isEmpty ? fallback : display.displayName
        }
    }
}

/// 同一套三环图形通过尺寸参数同时服务设置卡片和侧栏紧凑入口。
struct CombinedUsageRingsGraphic: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let items: [CombinedUsageItem]
    let expectedRingCount: Int
    let diameter: CGFloat
    let lineWidth: CGFloat
    var ringSpacing: CGFloat = 8

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let ringCount = min(max(expectedRingCount, items.count), 3)
        let ringStep = (lineWidth + ringSpacing) * 2

        ZStack {
            ForEach(0..<ringCount, id: \.self) { index in
                let ringDiameter = diameter - CGFloat(index) * ringStep

                ZStack {
                    Circle()
                        .stroke(tokens.tertiaryText.opacity(0.18), lineWidth: lineWidth)

                    if index < items.count,
                       let progress = items[index].window.remainingProgress {
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(
                                items[index].tint,
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .animation(
                                reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1),
                                value: progress
                            )
                    }
                }
                .frame(width: ringDiameter, height: ringDiameter)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}
