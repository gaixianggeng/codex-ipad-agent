import SwiftUI

/// 工作台导航的纯状态机。所有入口先在副本上归并，再一次性写回 SwiftUI，避免多个
/// `onChange` 在同一帧互相改写 selection、route 和 NavigationStack path。
struct WorkbenchNavigationState: Equatable {
    private(set) var route: WorkbenchRestorationRoute
    private(set) var selection: AppDestination?
    private(set) var compactSessionPath: [AppDestination]
    private(set) var compactWorkspacePath: [AppDestination]
    private(set) var compactSelectedTab: CompactWorkbenchTab
    private(set) var pendingSessionSelectionID: SessionID?

    init(route: WorkbenchRestorationRoute = .sessions) {
        self.route = route
        selection = Self.destination(for: route)
        compactSessionPath = []
        compactWorkspacePath = []
        pendingSessionSelectionID = nil

        switch route {
        case .sessions:
            compactSelectedTab = .sessions
        case .workspaces:
            compactSelectedTab = .workspaces
        case .session(let id, let source):
            let destination = AppDestination.session(id)
            switch source {
            case .sessions:
                compactSelectedTab = .sessions
                compactSessionPath = [destination]
            case .workspaces:
                compactSelectedTab = .workspaces
                compactWorkspacePath = [destination]
            }
        }
    }

    /// selectedSessionID 可能在“我的”或列表页继续保留，不能据此判断会话是否真的可见。
    func visibleSessionID(usesCompactNavigation: Bool) -> SessionID? {
        if usesCompactNavigation, compactSelectedTab == .me {
            return nil
        }
        if usesCompactNavigation {
            let path = compactSelectedTab == .workspaces ? compactWorkspacePath : compactSessionPath
            if case .subagent(_, let childID) = path.last {
                return childID
            }
        }
        guard case .session(let sessionID) = selection else {
            return nil
        }
        return sessionID
    }

    @discardableResult
    mutating func reduce(
        _ event: WorkbenchNavigationEvent,
        usesCompactNavigation: Bool,
        selectedSessionID: SessionID?
    ) -> WorkbenchNavigationEffect? {
        switch event {
        case .open(let destination, let requestedSource):
            return open(
                destination,
                requestedSource: requestedSource,
                usesCompactNavigation: usesCompactNavigation,
                selectedSessionID: selectedSessionID
            )

        case .synchronize(let restoredRoute):
            let preservesMe = isShowingMe(usesCompactNavigation: usesCompactNavigation)
            let preservedPendingSessionID = restoredRoute.detailSessionID == pendingSessionSelectionID
                ? pendingSessionSelectionID
                : nil
            route = restoredRoute
            selection = Self.destination(for: restoredRoute)
            pendingSessionSelectionID = preservedPendingSessionID
            guard usesCompactNavigation else {
                if preservesMe {
                    selection = .me
                }
                return nil
            }
            restoreCompactPath(for: restoredRoute)
            if preservesMe {
                compactSelectedTab = .me
                selection = .me
            }
            return nil

        case .selectionCommitted(let commit):
            let preservesMe = isShowingMe(usesCompactNavigation: usesCompactNavigation)
            pendingSessionSelectionID = nil
            switch commit.reason {
            case .invalidation:
                guard route.detailSessionID != nil else { return nil }
                applyRoot(route.rootPage, usesCompactNavigation: usesCompactNavigation)
                restoreMeIfNeeded(
                    preservesMe,
                    usesCompactNavigation: usesCompactNavigation
                )

            case .identityReplacement(let previousID):
                guard route.detailSessionID == previousID,
                      let sessionID = commit.sessionID else { return nil }
                applySession(
                    sessionID,
                    source: route.rootPage,
                    usesCompactNavigation: usesCompactNavigation,
                    replacesCompactPath: true
                )
                restoreMeIfNeeded(
                    preservesMe,
                    usesCompactNavigation: usesCompactNavigation
                )

            case .restoration:
                // Root 只允许仍与启动快照一致的恢复提交；这里再约束一次，
                // 防止恢复结果把用户后来进入的列表或其他详情重新覆盖。
                guard let sessionID = commit.sessionID,
                      route.detailSessionID == sessionID else { return nil }
                applySession(
                    sessionID,
                    source: route.rootPage,
                    usesCompactNavigation: usesCompactNavigation,
                    replacesCompactPath: true
                )
                restoreMeIfNeeded(
                    preservesMe,
                    usesCompactNavigation: usesCompactNavigation
                )

            case .notification:
                guard let sessionID = commit.sessionID else { return nil }
                applySession(
                    sessionID,
                    source: .sessions,
                    usesCompactNavigation: usesCompactNavigation,
                    replacesCompactPath: false
                )

            case .userOpen:
                guard let sessionID = commit.sessionID else { return nil }
                let source = route.detailSessionID == sessionID
                    ? route.rootPage
                    : (usesCompactNavigation ? activeRootPage : route.rootPage)
                applySession(
                    sessionID,
                    source: source,
                    usesCompactNavigation: usesCompactNavigation,
                    replacesCompactPath: false
                )
            }
            return nil

        case .compactPathChanged(let tab, let path):
            guard tab != .me else { return nil }
            compactSelectedTab = tab
            switch tab {
            case .sessions:
                compactSessionPath = path
            case .workspaces:
                compactWorkspacePath = path
            case .me:
                break
            }

            let destination = path.last ?? Self.rootDestination(for: tab)
            selection = destination
            switch destination {
            case .sessions:
                route = .sessions
                pendingSessionSelectionID = nil
            case .workspaces:
                route = .workspaces
                pendingSessionSelectionID = nil
            case .me:
                break
            case .session(let sessionID):
                route = .session(id: sessionID, source: Self.rootPage(for: tab))
            case .subagent(let parentID, _):
                selection = .session(parentID)
                route = .session(id: parentID, source: Self.rootPage(for: tab))
            }
            return effectForUserNavigation(to: destination, selectedSessionID: selectedSessionID)

        case .compactTabChanged(let tab):
            compactSelectedTab = tab
            guard tab != .me else {
                // “我的”是全局入口，切入时保留当前会话/工作区路由和两个 Tab 的历史栈。
                selection = .me
                return nil
            }
            let path = tab == .sessions ? compactSessionPath : compactWorkspacePath
            let destination = path.last ?? Self.rootDestination(for: tab)
            selection = destination
            switch destination {
            case .sessions:
                route = .sessions
                pendingSessionSelectionID = nil
            case .workspaces:
                route = .workspaces
                pendingSessionSelectionID = nil
            case .me:
                break
            case .session(let sessionID):
                route = .session(id: sessionID, source: Self.rootPage(for: tab))
            case .subagent(let parentID, _):
                selection = .session(parentID)
                route = .session(id: parentID, source: Self.rootPage(for: tab))
            }
            return effectForUserNavigation(to: destination, selectedSessionID: selectedSessionID)

        case .sessionSelectionFinished(let sessionID):
            if pendingSessionSelectionID == sessionID {
                pendingSessionSelectionID = nil
            }
            return nil
        }
    }

    /// “我的”是覆盖在工作台路由之上的全局页面。后台恢复、失效或会话 ID 替换
    /// 可以更新隐藏路由，但不能在没有用户导航意图时把当前页面抢走。
    private mutating func restoreMeIfNeeded(
        _ shouldRestore: Bool,
        usesCompactNavigation: Bool
    ) {
        guard shouldRestore else { return }
        selection = .me
        if usesCompactNavigation {
            compactSelectedTab = .me
        }
    }

    private mutating func open(
        _ destination: AppDestination,
        requestedSource: WorkbenchRootPage?,
        usesCompactNavigation: Bool,
        selectedSessionID: SessionID?
    ) -> WorkbenchNavigationEffect? {
        switch destination {
        case .sessions:
            applyRoot(.sessions, usesCompactNavigation: usesCompactNavigation)
        case .workspaces:
            applyRoot(.workspaces, usesCompactNavigation: usesCompactNavigation)
        case .me:
            selection = .me
            if usesCompactNavigation {
                compactSelectedTab = .me
            }
            return nil
        case .session(let sessionID):
            applySession(
                sessionID,
                source: requestedSource ?? (usesCompactNavigation ? activeRootPage : route.rootPage),
                usesCompactNavigation: usesCompactNavigation,
                replacesCompactPath: false
            )
        case .subagent(let parentID, let childID):
            applySubagent(
                parentID: parentID,
                childID: childID,
                source: requestedSource ?? (usesCompactNavigation ? activeRootPage : route.rootPage),
                usesCompactNavigation: usesCompactNavigation
            )
        }
        return effectForUserNavigation(to: destination, selectedSessionID: selectedSessionID)
    }

    private mutating func applyRoot(
        _ page: WorkbenchRootPage,
        usesCompactNavigation: Bool
    ) {
        pendingSessionSelectionID = nil
        switch page {
        case .sessions:
            route = .sessions
            selection = .sessions
            guard usesCompactNavigation else { return }
            compactSelectedTab = .sessions
            compactSessionPath = []
        case .workspaces:
            route = .workspaces
            selection = .workspaces
            guard usesCompactNavigation else { return }
            compactSelectedTab = .workspaces
            compactWorkspacePath = []
        }
    }

    private mutating func applySession(
        _ sessionID: SessionID,
        source: WorkbenchRootPage,
        usesCompactNavigation: Bool,
        replacesCompactPath: Bool
    ) {
        let destination = AppDestination.session(sessionID)
        route = .session(id: sessionID, source: source)
        selection = destination
        guard usesCompactNavigation else { return }

        switch source {
        case .sessions:
            compactSelectedTab = .sessions
            compactSessionPath = replacesCompactPath
                ? [destination]
                : Self.sessionPath(afterOpening: destination, currentPath: compactSessionPath)
        case .workspaces:
            compactSelectedTab = .workspaces
            compactWorkspacePath = replacesCompactPath
                ? [destination]
                : Self.sessionPath(afterOpening: destination, currentPath: compactWorkspacePath)
        }
    }

    private mutating func restoreCompactPath(for restoredRoute: WorkbenchRestorationRoute) {
        switch restoredRoute {
        case .sessions:
            compactSelectedTab = .sessions
            compactSessionPath = []
        case .workspaces:
            compactSelectedTab = .workspaces
            compactWorkspacePath = []
        case .session(let sessionID, let source):
            applySession(
                sessionID,
                source: source,
                usesCompactNavigation: true,
                replacesCompactPath: true
            )
        }
    }

    private mutating func applySubagent(
        parentID: SessionID,
        childID: SessionID,
        source: WorkbenchRootPage,
        usesCompactNavigation: Bool
    ) {
        let parentDestination = AppDestination.session(parentID)
        let childDestination = AppDestination.subagent(parentID: parentID, childID: childID)
        route = .session(id: parentID, source: source)
        selection = parentDestination
        guard usesCompactNavigation else { return }

        let path = [parentDestination, childDestination]
        switch source {
        case .sessions:
            compactSelectedTab = .sessions
            compactSessionPath = path
        case .workspaces:
            compactSelectedTab = .workspaces
            compactWorkspacePath = path
        }
    }

    private mutating func effectForUserNavigation(
        to destination: AppDestination,
        selectedSessionID: SessionID?
    ) -> WorkbenchNavigationEffect? {
        switch destination {
        case .sessions, .workspaces:
            // 返回列表本身就是显式用户意图；即使当前 ID 已为空也要推进选择代次，
            // 让仍在等待的恢复、通知和创建任务立即失效。
            return .returnToSessionList
        case .me:
            return nil
        case .session(let sessionID):
            guard selectedSessionID != sessionID,
                  pendingSessionSelectionID != sessionID else { return nil }
            // selectSession 包含网络恢复，可能跨帧；记录在途 ID，阻止同一个 UI 事件链重复启动。
            pendingSessionSelectionID = sessionID
            return .selectSession(sessionID)
        case .subagent(let parentID, _):
            guard selectedSessionID != parentID,
                  pendingSessionSelectionID != parentID else { return nil }
            pendingSessionSelectionID = parentID
            return .selectSession(parentID)
        }
    }

    private var activeRootPage: WorkbenchRootPage {
        switch compactSelectedTab {
        case .sessions:
            return .sessions
        case .workspaces:
            return .workspaces
        case .me:
            return route.rootPage
        }
    }

    private func isShowingMe(usesCompactNavigation: Bool) -> Bool {
        usesCompactNavigation ? compactSelectedTab == .me : selection == .me
    }

    private static func destination(for route: WorkbenchRestorationRoute) -> AppDestination {
        switch route {
        case .sessions:
            return .sessions
        case .workspaces:
            return .workspaces
        case .session(let id, _):
            return .session(id)
        }
    }

    private static func rootDestination(for tab: CompactWorkbenchTab) -> AppDestination {
        tab == .workspaces ? .workspaces : .sessions
    }

    private static func rootPage(for tab: CompactWorkbenchTab) -> WorkbenchRootPage {
        tab == .workspaces ? .workspaces : .sessions
    }

    private static func sessionPath(
        afterOpening destination: AppDestination,
        currentPath: [AppDestination]
    ) -> [AppDestination] {
        guard currentPath.last != destination else { return currentPath }

        var updatedPath = currentPath
        if let currentDestination = updatedPath.last,
           Self.isSessionDetailDestination(currentDestination) {
            // local:* 占位切到真实 ID 时替换当前详情，不能再 push 一层。
            updatedPath[updatedPath.index(before: updatedPath.endIndex)] = destination
        } else {
            updatedPath.append(destination)
        }
        return updatedPath
    }

    private static func isSessionDetailDestination(_ destination: AppDestination) -> Bool {
        switch destination {
        case .session, .subagent:
            return true
        case .sessions, .workspaces, .me:
            return false
        }
    }
}

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

    var usesSheetInspectorNavigation: Bool {
        !usesCompactNavigation && !usesAttachedInspector
    }

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
    func sessionInspectorPresentation(
        isPresented: Binding<Bool>,
        layout: WorkbenchLayout,
        relatedSubagent: Binding<SessionContextSubagent?>,
        parentSessionID: Binding<SessionID?>,
        onOpenSubagent: @escaping (SessionContextSubagent) -> Void,
        onCloseRelatedSubagent: @escaping () -> Void
    ) -> some View {
        modifier(
            SessionInspectorPresentation(
                isPresented: isPresented,
                layout: layout,
                relatedSubagent: relatedSubagent,
                parentSessionID: parentSessionID,
                onOpenSubagent: onOpenSubagent,
                onCloseRelatedSubagent: onCloseRelatedSubagent
            )
        )
    }
}

struct SessionInspectorPresentation: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var isPresented: Bool
    let layout: WorkbenchLayout
    @Binding var relatedSubagent: SessionContextSubagent?
    @Binding var parentSessionID: SessionID?
    let onOpenSubagent: (SessionContextSubagent) -> Void
    let onCloseRelatedSubagent: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if layout.usesAttachedInspector {
            content.inspector(isPresented: $isPresented) {
                Group {
                    if let relatedSubagent, let parentSessionID {
                        RelatedSessionConversationView(
                            relation: relatedSubagent,
                            parentSessionID: parentSessionID,
                            showsCloseButton: true,
                            onClose: onCloseRelatedSubagent
                        )
                    } else {
                        SessionInspectorView()
                    }
                }
                .inspectorColumnWidth(
                    min: layout.inspectorColumn.min,
                    ideal: layout.inspectorColumn.ideal,
                    max: layout.inspectorColumn.max
                )
                .environment(
                    \.openSubagentSession,
                    OpenSubagentSessionAction(handler: onOpenSubagent)
                )
            }
        } else {
            content.sheet(isPresented: $isPresented) {
                NavigationStack {
                    SessionInspectorView()
                        .environment(
                            \.openSubagentSession,
                            OpenSubagentSessionAction(handler: onOpenSubagent)
                        )
                        .navigationDestination(
                            isPresented: Binding(
                                get: {
                                    layout.usesSheetInspectorNavigation
                                        && relatedSubagent != nil
                                        && parentSessionID != nil
                                },
                                set: { presented in
                                    if !presented, layout.usesSheetInspectorNavigation {
                                        onCloseRelatedSubagent()
                                    }
                                }
                            )
                        ) {
                            if let relatedSubagent, let parentSessionID {
                                RelatedSessionConversationView(
                                    relation: relatedSubagent,
                                    parentSessionID: parentSessionID,
                                    showsCloseButton: false,
                                    onClose: {}
                                )
                            }
                        }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.text("ui.complete")) {
                            isPresented = false
                        }
                    }
                }
                .interactiveDismissDisabled(
                    layout.usesSheetInspectorNavigation && relatedSubagent != nil
                )
                .presentationDetents(horizontalSizeClass == .compact ? [.large] : [.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

/// 子 Agent 始终保留父会话为主选择，并使用独立订阅读取真实 Thread。
/// iPad 将它放入附着检查器列；iPhone 由外层 NavigationStack 原生 push。
struct RelatedSessionConversationView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let relation: SessionContextSubagent
    let parentSessionID: SessionID
    let showsCloseButton: Bool
    let onClose: () -> Void

    @State private var isLoading = true
    @State private var didFailToLoad = false
    @State private var measuredContentWidth: CGFloat?

    private var childSession: AgentSession? {
        sessionStore.sessionsByID[relation.id]
    }

    private var title: String {
        let nickname = relation.nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nickname, !nickname.isEmpty {
            return nickname
        }
        let childTitle = childSession?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let childTitle, !childTitle.isEmpty {
            return childTitle
        }
        return relation.displayName
    }

    private var isReadOnly: Bool {
        childSession?.allowsDirectInput != true || relation.canAcceptDirectInput != true
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        GeometryReader { proxy in
            let width = measuredContentWidth ?? proxy.size.width
            let layout = ConversationLayout(
                containerWidth: width,
                horizontalSizeClass: horizontalSizeClass,
                safeAreaInsets: proxy.safeAreaInsets
            )

            VStack(spacing: 0) {
                relatedHeader(tokens: tokens)
                Divider()
                    .overlay(tokens.border.opacity(0.72))

                ZStack {
                    ConversationTimelineView(layout: layout, sessionID: relation.id)

                    if isLoading {
                        ProgressView(L10n.text("ui.loading"))
                            .controlSize(.regular)
                    } else if didFailToLoad && childSession == nil {
                        ContentUnavailableView(
                            L10n.text("ui.sub_agent"),
                            systemImage: "exclamationmark.triangle",
                            description: Text(L10n.text("ui.sub_agent_unavailable"))
                        )
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { newWidth in
                guard newWidth > 0, measuredContentWidth != newWidth else { return }
                measuredContentWidth = newWidth
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                relatedFooter(tokens: tokens)
            }
            .background(tokens.background.ignoresSafeArea())
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .accessibilityIdentifier("subagent.conversation.\(relation.id)")
        .task(id: relation.id) {
            isLoading = true
            didFailToLoad = false
            let loaded = await sessionStore.prepareRelatedSession(
                relation,
                parentSessionID: parentSessionID
            )
            guard !Task.isCancelled else { return }
            didFailToLoad = loaded == nil
            isLoading = false
        }
        .onDisappear {
            sessionStore.stopRelatedSessionObservation(sessionID: relation.id)
        }
    }

    private func relatedHeader(tokens: ThemeTokens) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: statusSymbolName)
                        .foregroundStyle(statusColor(tokens: tokens))
                    Text(title)
                        .font(themeStore.uiFont(.subheadline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    if let role = relation.role, !role.isEmpty {
                        Text(role)
                    }
                    Text(childSession?.displayStatusText ?? statusText)
                    if isReadOnly {
                        Label(L10n.text("ui.read_only"), systemImage: "lock.fill")
                    }
                }
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(2)

                Text(L10n.text("ui.sub_agent_managed_by_parent"))
                    .font(themeStore.uiFont(.caption2))
                    .foregroundStyle(tokens.tertiaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsCloseButton {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(L10n.text("ui.close"))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, showsCloseButton ? 4 : 14)
        .padding(.vertical, 10)
    }

    private func relatedFooter(tokens: ThemeTokens) -> some View {
        Label(
            isReadOnly
                ? L10n.text("ui.sub_agent_managed_read_only")
                : L10n.text("ui.sub_agent_managed_by_parent"),
            systemImage: isReadOnly ? "lock.fill" : "person.2.fill"
        )
        .font(themeStore.uiFont(.caption, weight: .medium))
        .foregroundStyle(tokens.secondaryText)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(tokens.border.opacity(0.72))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var normalizedStatus: String {
        (childSession?.status ?? relation.status ?? "").lowercased()
    }

    private var statusText: String {
        switch normalizedStatus {
        case "active", "running", "inprogress", "in_progress", "started":
            return L10n.text("ui.running")
        case "completed", "complete", "success", "succeeded":
            return L10n.text("ui.complete")
        case "systemerror", "failed":
            return L10n.text("ui.abnormal")
        default:
            return L10n.text("ui.history")
        }
    }

    private var statusSymbolName: String {
        switch normalizedStatus {
        case "active", "running", "inprogress", "in_progress", "started":
            return "circle.fill"
        case "completed", "complete", "success", "succeeded":
            return "checkmark.circle.fill"
        case "systemerror", "failed":
            return "exclamationmark.triangle.fill"
        default:
            return "circle"
        }
    }

    private func statusColor(tokens: ThemeTokens) -> Color {
        switch normalizedStatus {
        case "active", "running", "inprogress", "in_progress", "started":
            return tokens.primaryAction
        case "completed", "complete", "success", "succeeded":
            return .green
        case "systemerror", "failed":
            return .red
        default:
            return tokens.tertiaryText
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
