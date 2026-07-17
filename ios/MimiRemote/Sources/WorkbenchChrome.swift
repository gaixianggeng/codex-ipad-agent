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
            // 手机导航栏同时有返回、连接状态、日志和设置按钮；标题必须主动让位，避免挤压工具按钮。
            titleMaxWidth = max(86, min(150, containerWidth - 250))
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
                                Button("完成") {
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

struct AgentWorkbenchTitle: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let maxWidth: CGFloat
    let horizontalOffset: CGFloat

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if shouldShowTitle {
                VStack(spacing: 2) {
                    Text(primaryText)
                        .font(themeStore.codeFont(.subheadline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    if let secondaryText {
                        HStack(spacing: 5) {
                            if historyProgress != nil {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(tokens.tertiaryText)
                                    .frame(width: 10, height: 10)
                            }
                            Text(secondaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.76)
                        }
                        .font(themeStore.codeFont(.caption2))
                        .foregroundStyle(tokens.tertiaryText)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: maxWidth)
        .offset(x: horizontalOffset)
    }

    private var historyProgress: HistoryLoadProgress? {
        sessionStore.historyLoadProgress(sessionID: sessionStore.selectedSessionID)
    }

    private var shouldShowTitle: Bool {
        historyProgress != nil ||
            sessionStore.selectedSession != nil ||
            sessionStore.selectedProject != nil
    }

    private var primaryText: String {
        if let session = sessionStore.selectedSession {
            return session.project.isEmpty ? "工作区" : session.project
        }
        return sessionStore.selectedProject?.name ?? "会话"
    }

    private var secondaryText: String? {
        if let historyProgress {
            // 历史请求没有真实网络进度，标题区只保留轻量状态，避免 32% 这类假进度占据主内容。
            return "正在\(historyProgress.title)…"
        }
        if let session = sessionStore.selectedSession {
            return session.title.isEmpty ? session.dir : session.title
        }
        return sessionStore.selectedProject?.path
    }
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
