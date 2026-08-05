import SwiftUI

/// MeeGo / Harmattan 图标底板不是规则圆角矩形，也不是完全对称的超椭圆。
/// 归一化 Bézier 控制点让上下边略平、左右边轻微收腰，并保留四角细微不同的饱满度。
struct WorkspaceIconMeeGoShape: Shape {
    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * x,
                y: rect.minY + rect.height * y
            )
        }

        var path = Path()
        path.move(to: point(0.27, 0.045))
        path.addCurve(
            to: point(0.75, 0.035),
            control1: point(0.41, 0.018),
            control2: point(0.61, 0.015)
        )
        path.addCurve(
            to: point(0.955, 0.26),
            control1: point(0.88, 0.045),
            control2: point(0.945, 0.14)
        )
        path.addCurve(
            to: point(0.95, 0.72),
            control1: point(0.985, 0.40),
            control2: point(0.98, 0.59)
        )
        path.addCurve(
            to: point(0.71, 0.955),
            control1: point(0.93, 0.85),
            control2: point(0.84, 0.945)
        )
        path.addCurve(
            to: point(0.26, 0.96),
            control1: point(0.57, 0.985),
            control2: point(0.40, 0.985)
        )
        path.addCurve(
            to: point(0.045, 0.70),
            control1: point(0.14, 0.945),
            control2: point(0.055, 0.84)
        )
        path.addCurve(
            to: point(0.055, 0.25),
            control1: point(0.018, 0.57),
            control2: point(0.025, 0.39)
        )
        path.addCurve(
            to: point(0.27, 0.045),
            control1: point(0.065, 0.13),
            control2: point(0.15, 0.055)
        )
        path.closeSubpath()
        return path
    }
}

enum WorkspaceStripLayout {
    static let horizontalPadding: CGFloat = 24
    /// 44pt 同时是 Apple 的最小命中尺寸和整条控件带的高度：选中项展开成带名称的胶囊，
    /// 其余收缩成头像圆，因此一行就能放下全部工作区，不再需要 138pt 的卡片。
    static let chipHeight: CGFloat = 44
    static let chipSpacing: CGFloat = 8
    /// 胶囊行 + 上下呼吸；工作区身份和状态改由下方状态行承担。
    static let stripHeight: CGFloat = 60
    /// 头像在展开与收缩两种形态下保持同一光学尺寸，切换时只有胶囊在变宽。
    static let chipIconSize: CGFloat = 28
    /// 胶囊行、状态行与详情内容共用同一个最大宽度，宽屏下三者左右边界一致。
    static let maxContentWidth: CGFloat = 920

    static func minimumContentWidth(viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - horizontalPadding * 2)
    }

    /// 粗略估算一行胶囊的总宽度，用来挑展开档位。
    /// 只需要够准到"多展开一个会不会挤"，估偏了也不会让胶囊够不到——
    /// 外层始终是可横向滚动的，这是它和 ViewThatFits 判定的关键区别。
    static func estimatedRowWidth(names: [String], expandedNames: Set<String>) -> CGFloat {
        guard !names.isEmpty else { return 0 }
        let widths = names.map { name -> CGFloat in
            guard expandedNames.contains(name) else { return chipHeight }
            // 图标 + 间距 + 文字 + 左右内边距。CJK 按一个字 ~14pt、其余 ~7.5pt 估。
            let textWidth = name.reduce(CGFloat.zero) { partial, character in
                partial + (character.isASCII ? 7.5 : 14)
            }
            return chipIconSize + 8 + textWidth + 24
        }
        return widths.reduce(0, +) + chipSpacing * CGFloat(names.count - 1)
    }

    /// 把有限的“展开名称”名额以选中项为中心向两侧发放。
    /// 名额为偶数时优先给右侧，符合从左到右的阅读顺序。
    static func centeredNameWindow(
        projectIDs: [String],
        limit: Int,
        aroundIndex selected: Int?
    ) -> Set<String> {
        guard limit > 0, !projectIDs.isEmpty else { return [] }
        guard limit < projectIDs.count else { return Set(projectIDs) }

        let center = selected.map { min(max($0, 0), projectIDs.count - 1) } ?? 0
        var lower = center
        var upper = center
        var chosen = [center]

        while chosen.count < limit {
            let canGoUpper = upper + 1 < projectIDs.count
            let canGoLower = lower - 1 >= 0
            guard canGoUpper || canGoLower else { break }

            if canGoUpper, chosen.count.isMultiple(of: 2) == false || !canGoLower {
                upper += 1
                chosen.append(upper)
            } else if canGoLower {
                lower -= 1
                chosen.append(lower)
            }
        }

        return Set(chosen.map { projectIDs[$0] })
    }
}

enum WorkspaceSessionAgeBoundary {
    static let staleInterval: TimeInterval = 12 * 60 * 60

    static func firstStaleIndex(
        in sessions: [AgentSession],
        excludingSessionIDs: Set<SessionID> = [],
        now: Date = Date()
    ) -> Int? {
        // 工作区会话已经按 SessionIndexStore.orderingDate 倒序排列；
        // 置顶会话可以跨越时间分组，因此排除后再寻找普通会话的 12 小时边界。
        sessions.firstIndex { session in
            !excludingSessionIDs.contains(session.id) &&
            now.timeIntervalSince(SessionIndexStore.orderingDate(for: session)) > staleInterval
        }
    }
}

/// View 层只记录“哪次调用仍有资格回写”，真实请求复用继续由 SessionStore single-flight 决定。
struct WorkspaceSessionLoadInvocationTokens {
    private var latestByKey: [WorkspaceSessionPresentationKey: UUID] = [:]

    @discardableResult
    mutating func begin(for key: WorkspaceSessionPresentationKey) -> UUID {
        let invocationID = UUID()
        latestByKey[key] = invocationID
        return invocationID
    }

    func isCurrent(_ invocationID: UUID, for key: WorkspaceSessionPresentationKey) -> Bool {
        latestByKey[key] == invocationID
    }

    mutating func remove(where shouldRemove: (WorkspaceSessionPresentationKey) -> Bool) {
        latestByKey = latestByKey.filter { !shouldRemove($0.key) }
    }
}

enum WorkspaceCatalogLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum WorkspaceCatalogLoadResult: Equatable {
    case loaded
    case cancelled
    case failed(String)
}

enum WorkspaceSessionLoadFailureDisposition: Equatable {
    case cancelled
    case failed(String)
}

/// Session 首屏和 catalog/open 使用同一套明确取消分类，避免 URL transport 取消落入用户错误态。
func workspaceSessionLoadFailureDisposition(_ error: Error) -> WorkspaceSessionLoadFailureDisposition {
    isCancellationError(error) ? .cancelled : .failed(error.localizedDescription)
}

struct WorkspaceCatalogRefreshScope: Equatable {
    let hostScope: HostScope
    let credentialsSuspended: Bool
}

struct WorkspaceSessionRefreshScope: Equatable {
    let presentationKey: WorkspaceSessionPresentationKey?
    let needsInitialLoad: Bool
}

/// Catalog 没有底层 single-flight；这里只隔离 View 调用的提交权，避免旧请求回写或把取消留成永久 loading。
struct WorkspaceCatalogLoadCoordinator {
    private(set) var state: WorkspaceCatalogLoadState = .idle
    private var currentInvocationID: UUID?

    @discardableResult
    mutating func begin() -> UUID {
        let invocationID = UUID()
        currentInvocationID = invocationID
        state = .loading
        return invocationID
    }

    func isCurrent(_ invocationID: UUID) -> Bool {
        currentInvocationID == invocationID
    }

    @discardableResult
    mutating func complete(
        _ invocationID: UUID,
        result: WorkspaceCatalogLoadResult,
        hasCachedProjects: Bool
    ) -> Bool {
        guard isCurrent(invocationID) else {
            return false
        }
        switch result {
        case .loaded:
            state = .loaded
        case .cancelled:
            state = hasCachedProjects ? .loaded : .idle
        case .failed(let message):
            state = .failed(message)
        }
        return true
    }
}

private struct WorkspaceGitInspectionTarget: Identifiable {
    let id: String
    let name: String
    let path: String

    init(project: AgentProject) {
        id = project.id
        name = project.name
        path = project.path
    }
}

/// 工作区只维护本地浏览选择。只有用户明确进入会话或新建会话时，才交给 SessionStore 改变活动上下文。
struct WorkspaceRootView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var appearanceStore: WorkspaceAppearanceStore

    let onStartSession: (AgentProject, WorkspaceSessionRuntimeChoice) -> Void
    let onOpenSession: (AgentSession) -> Void
    let embedsNavigationStack: Bool
    private let currentDate: () -> Date

    @State private var selectedWorkspaceID: String?
    @State private var selectedSessionRuntime: WorkspaceSessionRuntimeChoice = .codex
    @State private var catalogLoad = WorkspaceCatalogLoadCoordinator()
    @State private var runtimeSessionPagesByKey: [WorkspaceSessionPresentationKey: WorkspaceRuntimeSessionPageState] = [:]
    @State private var sessionLoadStates: [WorkspaceSessionPresentationKey: WorkspaceSessionLoadState] = [:]
    @State private var sessionLoadInvocationTokens = WorkspaceSessionLoadInvocationTokens()
    /// canonical Store 可以持有超采样得到的额外 root；这里仅记录每个工作区已经向用户展开多少条。
    /// key 带 HostScope、路径和 Runtime，避免跨 Mac、目录身份或引擎复用旧窗口。
    @State private var workspaceSessionVisibleLimitByKey: [WorkspaceSessionPresentationKey: Int] = [:]
    @State private var isPresentingOpenWorkspace = false
    @State private var gitInspectionTarget: WorkspaceGitInspectionTarget?
    /// 胶囊行的真实可用宽度，用来挑展开档位。0 表示尚未量到。
    @State private var measuredStripWidth: CGFloat = 0

    init(
        onStartSession: @escaping (AgentProject, WorkspaceSessionRuntimeChoice) -> Void,
        onOpenSession: @escaping (AgentSession) -> Void = { _ in },
        embedsNavigationStack: Bool = true,
        appearanceStore: WorkspaceAppearanceStore? = nil,
        initialWorkspaceID: String? = nil,
        currentDate: @escaping () -> Date = Date.init
    ) {
        self.onStartSession = onStartSession
        self.onOpenSession = onOpenSession
        self.embedsNavigationStack = embedsNavigationStack
        self.currentDate = currentDate
        _appearanceStore = StateObject(wrappedValue: appearanceStore ?? WorkspaceAppearanceStore())
        // 正常入口仍由 synchronizeSelection 恢复选择；显式初值只服务于确定性的预览和视觉快照。
        _selectedWorkspaceID = State(initialValue: initialWorkspaceID)
    }

    static func shouldEmbedNavigationStack(usesCompactNavigation: Bool) -> Bool {
        // 紧凑布局的 destination 已经在根导航栈内；只有独立/宽屏入口需要自己建栈。
        !usesCompactNavigation
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let catalogRefreshScope = WorkspaceCatalogRefreshScope(
            hostScope: appStore.activeHostScope,
            credentialsSuspended: appStore.isCredentialMemorySuspended
        )
        let selectedSessionPresentationKey = selectedProject.map(workspaceSessionPresentationKey(for:))
        let sessionRefreshScope = WorkspaceSessionRefreshScope(
            presentationKey: selectedSessionPresentationKey,
            needsInitialLoad: selectedSessionPresentationKey.map {
                runtimeSessionPagesByKey[$0]?.hasLoadedFirstPage != true
            } ?? false
        )

        Group {
            if embedsNavigationStack {
                NavigationStack {
                    navigationContent(tokens: tokens)
                }
            } else {
                // iPhone 紧凑布局已由 UnifiedWorkbenchShell 持有绑定 path 的导航栈。
                // 这里再嵌套 NavigationStack 会让 SwiftUI 在首次打开工作区时同时重算两层导航状态。
                navigationContent(tokens: tokens)
            }
        }
        .task(id: catalogRefreshScope) {
            // 后台会主动清空内存凭据；恢复完成发布 false 后，完整 scope 会确定性触发一次新刷新。
            guard !catalogRefreshScope.credentialsSuspended else {
                return
            }
            migrateLegacyWorkspaceAppearance()
            synchronizeSelection()
            // 每次进入工作区都做轻量目录同步，同时执行旧版自动候选数据清理；
            // 该请求不改变当前会话和 WebSocket，上层选择保持稳定。
            await refreshCatalog()
            synchronizeSelection()
        }
        .onChange(of: appStore.connectionProfiles) { _, _ in
            // 这里只重试本地偏好迁移，不重新请求目录。删除或修改重复 endpoint 后，
            // 当前 Profile 一旦成为唯一匹配，就应立即恢复旧版自定义图标值。
            migrateLegacyWorkspaceAppearance()
        }
        .task {
            // 两个新建入口先稳定渲染；Claude 通道能力独立在后台刷新，不能让网络往返
            // 决定按钮何时才出现在布局里。
            await sessionStore.refreshAppServerModelOptions()
        }
        .task(id: sessionRefreshScope) {
            guard sessionRefreshScope.needsInitialLoad,
                  let presentationKey = sessionRefreshScope.presentationKey,
                  let project = sessionStore.sidebarProjects.first(where: {
                      $0.id == presentationKey.workspaceID && $0.path == presentationKey.workspacePath
                  })
            else { return }
            await refreshWorkspaceSessions(project: project, presentationKey: presentationKey)
        }
        .task(id: neighborPrefetchScope) {
            // 当前页优先：等它自己的 task 先占住 single-flight，再补相邻页。
            for project in neighborWorkspaceProjects {
                guard !Task.isCancelled else { return }
                // 已有权威首屏的工作区不再重复请求；预取只负责补齐从没拉过的相邻页。
                guard sessionStore.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id) else {
                    continue
                }
                await refreshWorkspaceSessions(
                    project: project,
                    presentationKey: workspaceSessionPresentationKey(for: project)
                )
            }
        }
        .onChange(of: sessionStore.sidebarProjects.map(\.id)) { _, _ in
            synchronizeSelection()
        }
        .onChange(of: sessionStore.hasClaudeRuntimeChannel) { _, isAvailable in
            if !isAvailable, selectedSessionRuntime == .claude {
                selectedSessionRuntime = .codex
            }
        }
        .sheet(isPresented: $isPresentingOpenWorkspace) {
            OpenWorkspaceSheet { workspaceID in
                // 工作区页使用本地浏览选择；Sheet 成功打开目录后要显式切到新工作区，
                // 不能依赖全局 selectedProjectID，否则会破坏浏览选择与会话上下文的解耦。
                selectedWorkspaceID = workspaceID
            }
        }
        .sheet(item: $gitInspectionTarget) { target in
            NavigationStack {
                DiffPanelView(workspacePath: target.path)
                    .navigationTitle(target.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.text("ui.complete")) {
                                gitInspectionTarget = nil
                            }
                        }
                    }
            }
            .presentationDetents([.large])
        }
        .background(tokens.background.ignoresSafeArea())
    }

    private func migrateLegacyWorkspaceAppearance() {
        appearanceStore.migrateLegacyValueIfNeeded(
            profileID: appStore.activeHostScope.profileID,
            endpoint: appStore.endpoint,
            profiles: appStore.connectionProfiles
        )
    }

    private func navigationContent(tokens: ThemeTokens) -> some View {
        workspaceBrowser(tokens: tokens)
            .accessibilityIdentifier("workspace.browser")
            // 标题与底部 Tab 的“工作区”标签完全重复，白占一条 44pt 横带；
            // 当前工作区的身份改由下方胶囊行表达。
            // “打开目录”也从导航栏移到胶囊行末端——它和切换工作区是同一类操作，
            // 分成上下两行只会在顶部留出一整条空白。
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
    }

    private func openDirectoryButton(tokens: ThemeTokens) -> some View {
        Button {
            isPresentingOpenWorkspace = true
        } label: {
            WorkbenchChromeIcon(systemName: "folder.badge.plus")
                .workbenchChromeCircle(tokens: tokens)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.secondaryText)
        .accessibilityLabel(L10n.text("ui.open_directory"))
        .accessibilityIdentifier("workspace.toolbar.openDirectory")
    }

    @ViewBuilder
    private func workspaceBrowser(tokens: ThemeTokens) -> some View {
        if sessionStore.sidebarProjects.isEmpty {
            if catalogLoad.state == .loading {
                workspaceLoadingState(tokens: tokens)
            } else {
                workspaceEmptyState(tokens: tokens)
            }
        } else {
            VStack(spacing: 0) {
                workspaceStrip(tokens: tokens)

                // 原来这里是一条硬分割线。控件带与内容之间的边界改由 scroll edge effect 表达，
                // 选中工作区的分支、Git 状态和活跃时间收进一行状态摘要。
                projectPager(tokens: tokens)
            }
            .background(tokens.background.ignoresSafeArea())
        }
    }

    /// 每个工作区一页，横向分页切换。用 ScrollView 的分页行为而不是 TabView：
    /// `scrollPosition(id:)` 是连续绑定，胶囊行能跟着滑动过程走；TabView 的 selection
    /// 要等落定才更新，滑到一半上方胶囊不动、松手才跳，正好丢掉跟手感。
    /// 分页物理特性（跟手、速度投射、可中断反向）由系统提供，不自己写 DragGesture。
    private func projectPager(tokens: ThemeTokens) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(sessionStore.sidebarProjects) { project in
                    // 状态行下沉进详情视图，与会话列表共用同一组内边距并紧贴列表：
                    // 它描述的是“这个列表属于哪个工作区”，悬在胶囊行下方会读成孤立的元数据。
                    workspaceDetail(project: project) {
                        workspaceStatusLine(project: project, tokens: tokens)
                    }
                    .refreshable {
                        await refreshWorkspaceContent(projectID: project.id)
                    }
                    .containerRelativeFrame(.horizontal)
                    // 离开视口中心的页面按进度缩小并变淡。scrollTransition 的相位跟着
                    // 手指走，所以缩放是 1:1 可中断的，而不是松手后再播一段固定动画。
                    .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                        content
                            .scaleEffect(phase.isIdentity ? 1 : 0.93)
                            .opacity(phase.isIdentity ? 1 : 0.55)
                    }
                    .id(project.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        // 直接绑定唯一的选择来源：点胶囊会滚动分页，滑动分页会回写胶囊选中态。
        .scrollPosition(id: $selectedWorkspaceID, anchor: .center)
        .scrollIndicators(.hidden)
    }

    private func workspaceLoadingState(tokens: ThemeTokens) -> some View {
        VStack(spacing: 0) {
            workspaceStrip(tokens: tokens)

            Divider()
                .overlay(tokens.border.opacity(0.7))

            ProgressView(L10n.text("ui.loading_workspace"))
                .font(themeStore.uiFont(.callout, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
                .tint(tokens.primaryAction)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(tokens.background.ignoresSafeArea())
        .accessibilityIdentifier("workspace.loadingState")
    }

    private func workspaceEmptyState(tokens: ThemeTokens) -> some View {
        let isFailure: Bool
        if case .failed = catalogLoad.state {
            isFailure = true
        } else {
            isFailure = false
        }
        let tint = isFailure ? tokens.warning : tokens.primaryAction

        return VStack(spacing: 0) {
            Spacer(minLength: 40)

            VStack(spacing: 18) {
                Image(systemName: emptyWorkspaceSymbol)
                    .font(themeStore.uiFont(size: 28, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(width: 64, height: 64)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(spacing: 7) {
                    Text(emptyWorkspaceTitle)
                        .font(themeStore.uiFont(.title3, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)

                    Text(emptyWorkspaceMessage)
                        .font(themeStore.uiFont(.callout))
                        .foregroundStyle(tokens.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }

                Button {
                    if isFailure {
                        Task { await refreshCatalog() }
                    } else {
                        isPresentingOpenWorkspace = true
                    }
                } label: {
                    Label(isFailure ? L10n.text("ui.reload") : L10n.text("ui.open_directory"), systemImage: isFailure ? "arrow.clockwise" : "folder.badge.plus")
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(tokens.primaryAction)
                .accessibilityIdentifier("workspace.emptyAction")
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 32)
            .padding(.vertical, 36)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.background.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.emptyState")
    }

    private func workspaceStrip(tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                // 收缩成头像是一种压缩手法：只有横向真的放不下时才该发生，
                // 而且必须渐进——只有“全展开”和“只展开选中项”两档时，
                // 项目一多就会整体跌到最压缩那一档，宽屏上白白浪费空间。
                //
                // 这里不用 ViewThatFits：它只会渲染被选中的那一个候选，
                // 于是“放得下”的档位全都是不可滚动的 HStack，一旦估算与实际渲染有出入，
                // 超出屏幕的胶囊就永远够不到。改成自己按可用宽度挑档位，
                // 外层恒为 ScrollView，估偏了最多是多展开/少展开一个名字。
                // 不用 GeometryReader：它会贪婪占满、首帧报 0 宽度，在离屏渲染
                // （视觉快照）里和真机行为不一致。onGeometryChange 只观测已经排好的
                // 真实宽度，不参与布局协商。
                ScrollView(.horizontal, showsIndicators: false) {
                    projectChips(
                        expandedNameLimit: expandedNameLimit(forWidth: measuredStripWidth),
                        tokens: tokens
                    )
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { newWidth in
                    guard newWidth > 0, measuredStripWidth != newWidth else { return }
                    measuredStripWidth = newWidth
                }
                .onChange(of: selectedWorkspaceID) { _, selectedID in
                    guard let selectedID else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
                .onAppear {
                    guard let selectedWorkspaceID else { return }
                    // 恢复已有选择时主动定位胶囊，保证选中项不会留在横向列表的屏幕外。
                    DispatchQueue.main.async {
                        proxy.scrollTo(selectedWorkspaceID, anchor: .center)
                    }
                }
            }

            // “打开目录”与切换工作区是同一类操作，和胶囊行齐平；
            // 它固定在行尾，不参与胶囊的横向滚动。
            openDirectoryButton(tokens: tokens)
        }
        .padding(.horizontal, WorkspaceStripLayout.horizontalPadding)
        .frame(height: WorkspaceStripLayout.stripHeight)
        .accessibilityLabel(L10n.text("ui.workspace_list"))
    }

    /// 在给定宽度下能展开多少个名称。从最宽的档位往下退，取第一个装得下的。
    private func expandedNameLimit(forWidth width: CGFloat) -> Int {
        // 宽度尚未量到时按全展开渲染：胶囊行始终可横向滚动，
        // 首帧偏宽只是多展开几个名字，而塌成 0 会让整行只剩一个胶囊。
        guard width > 0 else { return .max }
        let projects = sessionStore.sidebarProjects
        guard !projects.isEmpty else { return 0 }

        let names = projects.map(\.name)
        let selectedIndex = projects.firstIndex { $0.id == selectedWorkspaceID }
        let ids = projects.map(\.id)

        for limit in [Int.max, 8, 6, 4, 3, 2, 1] {
            let expandedIDs = WorkspaceStripLayout.centeredNameWindow(
                projectIDs: ids,
                limit: limit,
                aroundIndex: selectedIndex
            )
            let expandedNames = Set(
                zip(ids, names).compactMap { expandedIDs.contains($0.0) ? $0.1 : nil }
            )
            let estimate = WorkspaceStripLayout.estimatedRowWidth(
                names: names,
                expandedNames: expandedNames
            )
            if estimate <= width {
                return limit
            }
        }
        return 0
    }

    /// 各档位共用同一份胶囊构造，只有展开名称的数量不同；
    /// 分支结构必须一致，否则 ViewThatFits 切换档位时会重建整行而不是平滑改宽。
    /// `expandedNameLimit` 为 0 表示只展开选中项。
    private func projectChips(expandedNameLimit: Int, tokens: ThemeTokens) -> some View {
        let profileID = appStore.activeHostScope.profileID
        let projectIDs = sessionStore.sidebarProjects.map(\.id)
        let iconStyle = appearanceStore.style(profileID: profileID)
        let characterAssignments = appearanceStore.characterAssignments(
            style: iconStyle,
            profileID: profileID,
            projectIDs: projectIDs
        )
        let emojiAssignments = appearanceStore.emojiAssignments(
            profileID: profileID,
            projectIDs: projectIDs
        )
        // 名额以选中项为中心向两侧分配。从最左边开始发会让选中项右侧的邻居先被收缩，
        // 视线跟着选择移动时出现断裂——这正是“滑到哪个才放大哪个”被破坏的原因。
        let selectedIndex = sessionStore.sidebarProjects.firstIndex { $0.id == selectedWorkspaceID }
        let expandedNameIDs = WorkspaceStripLayout.centeredNameWindow(
            projectIDs: projectIDs,
            limit: expandedNameLimit,
            aroundIndex: selectedIndex
        )

        // 胶囊数量等于本机工作区数量，且每个都很轻；用 HStack 而不是 LazyHStack，
        // 否则选中项展开时宽度动画会因为懒加载复用而跳变。
        return HStack(spacing: WorkspaceStripLayout.chipSpacing) {
            if catalogLoad.state == .loading && sessionStore.sidebarProjects.isEmpty {
                ForEach(0..<4, id: \.self) { index in
                    WorkspaceProjectChip(
                        project: AgentProject(id: "loading-\(index)", name: L10n.text("ui.loading_workspace"), path: "/Users/you/code/project"),
                        profileID: profileID,
                        appearanceStore: appearanceStore,
                        iconStyle: iconStyle,
                        displayedCharacter: appearanceStore.character(
                            style: iconStyle,
                            profileID: profileID,
                            projectID: "loading-\(index)"
                        ),
                        displayedEmoji: appearanceStore.emoji(
                            profileID: profileID,
                            projectID: "loading-\(index)"
                        ),
                        unavailableCharacterIDs: [],
                        unavailableEmoji: [],
                        gitSummary: nil,
                        hasRunningSession: false,
                        isUnavailable: false,
                        isSelected: false,
                        showsName: expandedNameLimit > 0,
                        distanceFromSelection: 0,
                        allowsCustomization: false,
                        tokens: tokens,
                        action: {},
                        onOpenGitChanges: {},
                        onConfirmRemove: {}
                    )
                    .redacted(reason: .placeholder)
                }
            } else {
                ForEach(sessionStore.sidebarProjects) { project in
                    let projectSessions = sessionStore.sessions(forProjectID: project.id)
                    let displayedCharacter = characterAssignments[project.id]
                        ?? appearanceStore.character(
                            style: iconStyle,
                            profileID: profileID,
                            projectID: project.id
                        )
                    let displayedEmoji = emojiAssignments[project.id]
                        ?? appearanceStore.emoji(profileID: profileID, projectID: project.id)
                    let unavailableCharacterIDs: Set<String> =
                        projectIDs.count
                            <= WorkspaceAppearanceStore.characters(for: iconStyle).count
                        ? Set(
                            characterAssignments.compactMap { otherProjectID, character in
                                otherProjectID == project.id ? nil : character.id
                            }
                        )
                        : []
                    let unavailableEmoji: Set<String> =
                        projectIDs.count <= WorkspaceAppearanceStore.builtInEmoji.count
                        ? Set(
                            emojiAssignments.compactMap { otherProjectID, emoji in
                                otherProjectID == project.id ? nil : emoji
                            }
                        )
                        : []
                    WorkspaceProjectChip(
                        project: project,
                        profileID: profileID,
                        appearanceStore: appearanceStore,
                        iconStyle: iconStyle,
                        displayedCharacter: displayedCharacter,
                        displayedEmoji: displayedEmoji,
                        unavailableCharacterIDs: unavailableCharacterIDs,
                        unavailableEmoji: unavailableEmoji,
                        gitSummary: sessionStore.workspaceGitSummaryByPath[project.path],
                        hasRunningSession: projectSessions.contains(where: \.isRunning),
                        isUnavailable: sessionStore.isWorkspaceUnavailable(project.id),
                        isSelected: selectedWorkspaceID == project.id,
                        showsName: expandedNameIDs.contains(project.id) || selectedWorkspaceID == project.id,
                        distanceFromSelection: selectedIndex.map { abs(($0) - (projectIDs.firstIndex(of: project.id) ?? $0)) } ?? 0,
                        allowsCustomization: true,
                        tokens: tokens
                    ) {
                        // 工作区页面只更新本地浏览选择，避免切换胶囊时意外改变当前会话上下文。
                        selectedWorkspaceID = project.id
                    } onOpenGitChanges: {
                        gitInspectionTarget = WorkspaceGitInspectionTarget(project: project)
                    } onConfirmRemove: {
                        removeWorkspace(project)
                    }
                    .id(project.id)
                }
            }
        }
        // 这里不能加 maxWidth 约束：ViewThatFits 靠子视图的固有宽度判断放不放得下，
        // 一旦声明 .infinity，展开态会永远“合身”，窄屏上就退不回压缩态。
        .padding(.vertical, 8)
    }

    /// 胶囊收缩后，选中工作区的分支、Git 状态和活跃时间集中在这一行。
    /// 这些信息只描述当前选中项，因此固定在胶囊行下方，不随会话列表滚走。
    private func workspaceStatusLine(project: AgentProject, tokens: ThemeTokens) -> some View {
        let projectSessions = sessionStore.sessions(forProjectID: project.id)
        let gitSummary = sessionStore.workspaceGitSummaryByPath[project.path]
        let isGitSummaryLoading = sessionStore.refreshingWorkspaceGitSummaryPaths.contains(project.path)

        return TimelineView(.periodic(from: .now, by: 60)) { _ in
            // TimelineView 只负责按分钟触发刷新；时间来源可在视觉测试中固定。
            let summary = WorkspaceStatusSummary.make(
                gitSummary: gitSummary,
                isUnavailable: sessionStore.isWorkspaceUnavailable(project.id),
                hasRunningSession: projectSessions.contains(where: \.isRunning),
                lastActivityAt: workspaceActivityDate(projectID: project.id, sessions: projectSessions),
                now: currentDate()
            )

            // 分隔点只能出现在两个都存在的段之间。逐段自己带一个前导分隔符时，
            // 缺少分支的非 Git 项目会以一个悬空的“·”开头。
            let showsBranchSlot = summary.branch != nil || isGitSummaryLoading

            HStack(spacing: 6) {
                if let branch = summary.branch {
                    Label(branch, systemImage: "point.3.connected.trianglepath.dotted")
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if isGitSummaryLoading {
                    Capsule()
                        .fill(tokens.elevatedSurface.opacity(0.56))
                        .frame(width: 58, height: 10)
                }

                if let status = summary.status {
                    if showsBranchSlot {
                        statusSeparator(tokens: tokens)
                    }
                    // 只有真正需要注意的状态（有改动、落后、需重试）才着色；
                    // “已同步”这类稳态用三级文字，不再为每种状态都点一颗彩色圆点。
                    Text(status.text)
                        .foregroundStyle(status.needsAttention ? status.color(tokens: tokens) : tokens.tertiaryText)
                        .lineLimit(1)
                        .fixedSize()
                }

                if let activity = summary.activityText {
                    if showsBranchSlot || summary.status != nil {
                        statusSeparator(tokens: tokens)
                    }
                    Text(activity)
                        .lineLimit(1)
                        .fixedSize()
                }

                Spacer(minLength: 0)
            }
            .font(themeStore.uiFont(.caption))
            .foregroundStyle(tokens.secondaryText)
            // 状态行现在渲染在会话列表容器内部，那层已经有横向内边距了；
            // 这里再加一次会比筛选行和会话行多缩进一截。
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("workspace.statusLine")
        }
    }

    private func statusSeparator(tokens: ThemeTokens) -> some View {
        Text(verbatim: "·")
            .foregroundStyle(tokens.tertiaryText)
            .accessibilityHidden(true)
    }

    private func workspaceDetail<StatusLine: View>(
        project: AgentProject,
        @ViewBuilder statusLine: () -> StatusLine
    ) -> some View {
        let presentationKey = workspaceSessionPresentationKey(for: project)
        let cachedPageState = runtimeSessionPagesByKey[presentationKey]
        // Store 已有首屏时先按当前 Runtime 投影，避免进入工作区或切换筛选后先退回骨架屏；
        // authoritative 请求仍会在后台刷新，并在返回后接管独立 cursor 与 hasMore。
        let storedRuntimeSessions = sessionStore.sessions(forProjectID: project.id).filter { session in
            sessionStore.isListableSession(session)
                && CodexAppServerSessionRuntime.normalizedRuntimeProvider(session.runtimeProvider ?? session.source)
                    == presentationKey.runtimeProvider
        }
        let loadedSessions = cachedPageState?.reconciledSessions(with: storedRuntimeSessions) ?? storedRuntimeSessions
        let loadState = sessionLoadState(for: presentationKey)
        let visibleLimit = workspaceSessionVisibleLimit(for: presentationKey)
        return WorkspaceDetailView(
            statusLine: statusLine(),
            // Store 保留全部已取回 root 作为预取缓冲；工作区详情按 20 条窗口逐步展开，
            // 不能让一次超采样把首屏从 20 条直接放大到 50 条。
            recentSessions: WorkspaceSessionPresentation.visibleSessions(
                loadedSessions,
                limit: visibleLimit
            ),
            unreadHistorySessionIDs: sessionStore.unreadHistorySessionIDs,
            sessionLoadState: loadState,
            hasInitialSessionContent: cachedPageState?.hasLoadedFirstPage == true || !storedRuntimeSessions.isEmpty,
            canLoadMoreSessions: WorkspaceSessionPresentation.canLoadMore(
                loadedCount: loadedSessions.count,
                visibleLimit: visibleLimit,
                remoteHasMore: cachedPageState?.hasMore == true
            ),
            selectedRuntime: $selectedSessionRuntime,
            claudeChannelAvailable: sessionStore.hasClaudeRuntimeChannel,
            currentDate: currentDate,
            onRefreshSessions: {
                Task {
                    await refreshWorkspaceSessions(project: project, presentationKey: presentationKey)
                }
            },
            onLoadMoreSessions: {
                await loadMoreWorkspaceSessions(project: project, presentationKey: presentationKey)
            },
            onStartSession: { runtimeChoice in
                onStartSession(project, runtimeChoice)
            },
            onOpenSession: { session in
                onOpenSession(session)
            }
        )
    }

    private var selectedProject: AgentProject? {
        guard let selectedWorkspaceID else {
            return nil
        }
        return sessionStore.sidebarProjects.first { $0.id == selectedWorkspaceID }
    }

    private func workspaceActivityDate(projectID: String, sessions: [AgentSession]) -> Date? {
        let sessionDate = sessions
            .map { SessionIndexStore.orderingDate(for: $0) }
            .filter { $0 != .distantPast }
            .max()
        return sessionDate
            ?? sessionStore.recentWorkspaces.first(where: { $0.id == projectID })?.lastOpenedAt
    }

    private var emptyWorkspaceTitle: String {
        if case .failed = catalogLoad.state { return L10n.text("ui.unable_to_load_workspace") }
        return L10n.text("ui.no_workspace_yet")
    }

    private var emptyWorkspaceSymbol: String {
        if case .failed = catalogLoad.state { return "exclamationmark.triangle" }
        return "folder.badge.plus"
    }

    private var emptyWorkspaceMessage: String {
        if case .failed(let message) = catalogLoad.state { return message }
        return L10n.text("ui.once_the_directory_is_open_you_can_browse")
    }

    private func synchronizeSelection() {
        let projects = sessionStore.sidebarProjects
        guard !projects.isEmpty else {
            selectedWorkspaceID = nil
            return
        }
        if let selectedWorkspaceID,
           projects.contains(where: { $0.id == selectedWorkspaceID }) {
            return
        }
        if let selectedWorkspaceID {
            let retainedID = sessionStore.retainedWorkspaceID(for: selectedWorkspaceID)
            if projects.contains(where: { $0.id == retainedID }) {
                self.selectedWorkspaceID = retainedID
                return
            }
        }
        selectedWorkspaceID = sessionStore.selectedProjectID.flatMap { selectedID in
            projects.contains(where: { $0.id == selectedID }) ? selectedID : nil
        } ?? projects.first?.id
    }

    private func removeWorkspace(_ project: AgentProject) {
        guard selectedWorkspaceID != project.id else { return }
        runtimeSessionPagesByKey = runtimeSessionPagesByKey.filter { $0.key.workspaceID != project.id }
        sessionLoadStates = sessionLoadStates.filter { $0.key.workspaceID != project.id }
        sessionLoadInvocationTokens.remove { $0.workspaceID == project.id }
        workspaceSessionVisibleLimitByKey = workspaceSessionVisibleLimitByKey.filter {
            $0.key.workspaceID != project.id
        }
        sessionStore.forgetWorkspace(project)
    }

    /// LazyHStack 会预先构建左右相邻页；提前取回它们的首屏窗口，
    /// 否则滑动落地时才开始请求，会先看到骨架屏再跳成列表。
    /// 只取紧邻的前后各一页，且只取当前 Runtime——不做整库预热。
    private var neighborWorkspaceProjects: [AgentProject] {
        let projects = sessionStore.sidebarProjects
        guard let index = projects.firstIndex(where: { $0.id == selectedWorkspaceID }) else {
            return []
        }
        return [index - 1, index + 1]
            .filter { projects.indices.contains($0) }
            .map { projects[$0] }
    }

    private var neighborPrefetchScope: String {
        (
            [appStore.activeHostScope.profileID,
             selectedSessionRuntime.rawValue,
             selectedWorkspaceID ?? ""]
                + neighborWorkspaceProjects.map(\.id)
        ).joined(separator: "|")
    }

    private func workspaceSessionPresentationKey(for project: AgentProject) -> WorkspaceSessionPresentationKey {
        WorkspaceSessionPresentationKey(
            hostScope: appStore.activeHostScope,
            workspaceID: project.id,
            workspacePath: project.path,
            runtimeProvider: selectedSessionRuntime.runtimeProvider
        )
    }

    private func workspaceSessionVisibleLimit(for key: WorkspaceSessionPresentationKey) -> Int {
        max(
            SessionStore.initialSessionPageLimit,
            workspaceSessionVisibleLimitByKey[key] ?? SessionStore.initialSessionPageLimit
        )
    }

    private func loadMoreWorkspaceSessions(
        project: AgentProject,
        presentationKey: WorkspaceSessionPresentationKey
    ) async {
        let currentVisibleLimit = workspaceSessionVisibleLimit(for: presentationKey)
        let targetVisibleLimit = WorkspaceSessionPresentation.nextVisibleLimit(
            current: currentVisibleLimit,
            pageSize: SessionStore.expandedSessionPageLimit
        )
        var pageState = runtimeSessionPagesByKey[presentationKey] ?? WorkspaceRuntimeSessionPageState()
        let loadedCount = pageState.sessions.count
        if WorkspaceSessionPresentation.shouldRequestRemotePage(
            loadedCount: loadedCount,
            targetVisibleLimit: targetVisibleLimit,
            remoteHasMore: pageState.hasMore
        ) {
            do {
                let page = try await sessionStore.workspaceRuntimeSessionsPage(
                    projectID: project.id,
                    runtimeProvider: presentationKey.runtimeProvider,
                    cursor: pageState.nextCursor,
                    limit: SessionStore.expandedSessionPageLimit,
                    excludingListableSessionIDs: Set(pageState.sessions.map(\.id))
                )
                pageState.append(page)
                runtimeSessionPagesByKey[presentationKey] = pageState
                sessionLoadStates[presentationKey] = .loaded
            } catch {
                guard !isCancellationError(error) else { return }
                sessionLoadStates[presentationKey] = .failed(error.localizedDescription)
            }
        }

        guard appStore.activeHostScope == presentationKey.hostScope,
              let currentProject = sessionStore.sidebarProjects.first(where: { $0.id == project.id }),
              currentProject.path == presentationKey.workspacePath
        else {
            return
        }
        workspaceSessionVisibleLimitByKey[presentationKey] = WorkspaceSessionPresentation.committedVisibleLimit(
            current: currentVisibleLimit,
            target: targetVisibleLimit,
            loadedCount: runtimeSessionPagesByKey[presentationKey]?.sessions.count ?? pageState.sessions.count
        )
    }

    private func refreshCatalog(forceGitSummary: Bool = false) async {
        let invocationID = catalogLoad.begin()
        do {
            try await sessionStore.refreshWorkspaceCatalog()
            guard catalogLoad.isCurrent(invocationID) else {
                return
            }
            guard !Task.isCancelled else {
                catalogLoad.complete(
                    invocationID,
                    result: .cancelled,
                    hasCachedProjects: !sessionStore.sidebarProjects.isEmpty
                )
                return
            }
            catalogLoad.complete(
                invocationID,
                result: .loaded,
                hasCachedProjects: !sessionStore.sidebarProjects.isEmpty
            )
            await sessionStore.refreshWorkspaceGitSummaries(
                for: sessionStore.sidebarProjects,
                force: forceGitSummary
            )
        } catch {
            catalogLoad.complete(
                invocationID,
                result: isCancellationError(error) ? .cancelled : .failed(error.localizedDescription),
                hasCachedProjects: !sessionStore.sidebarProjects.isEmpty
            )
        }
    }

    private func refreshWorkspaceContent(projectID: String) async {
        await refreshCatalog(forceGitSummary: true)
        guard !Task.isCancelled,
              selectedWorkspaceID == projectID,
              let project = sessionStore.sidebarProjects.first(where: { $0.id == projectID })
        else {
            return
        }
        let presentationKey = workspaceSessionPresentationKey(for: project)
        await refreshWorkspaceSessions(project: project, presentationKey: presentationKey)
    }

    private func refreshWorkspaceSessions(
        project: AgentProject,
        presentationKey: WorkspaceSessionPresentationKey
    ) async {
        // 每个 Runtime 独立占有提交 token；切换筛选不会让旧请求覆盖当前 Runtime 的缓存。
        let invocationID = sessionLoadInvocationTokens.begin(for: presentationKey)
        let canonicalSessionIDsBeforeLoad = Set<SessionID>(
            sessionStore.sessions(forProjectID: project.id).compactMap { session in
                guard sessionStore.isListableSession(session),
                      CodexAppServerSessionRuntime.normalizedRuntimeProvider(
                          session.runtimeProvider ?? session.source
                      ) == presentationKey.runtimeProvider
                else {
                    return nil
                }
                return session.id
            }
        )
        sessionLoadStates[presentationKey] = .loading
        do {
            let page = try await sessionStore.workspaceRuntimeSessionsPage(
                projectID: project.id,
                runtimeProvider: presentationKey.runtimeProvider,
                cursor: nil,
                limit: SessionStore.initialSessionPageLimit
            )
            guard sessionLoadInvocationTokens.isCurrent(invocationID, for: presentationKey) else {
                return
            }
            guard !Task.isCancelled,
                  appStore.activeHostScope == presentationKey.hostScope,
                  sessionStore.sidebarProjects.contains(where: {
                      $0.id == project.id && $0.path == presentationKey.workspacePath
                  })
            else {
                sessionLoadStates[presentationKey] = fallbackSessionLoadState(for: presentationKey)
                return
            }
            var nextState = WorkspaceRuntimeSessionPageState()
            nextState.replace(
                with: page,
                canonicalSessionIDsBeforeLoad: canonicalSessionIDsBeforeLoad
            )
            runtimeSessionPagesByKey[presentationKey] = nextState
            workspaceSessionVisibleLimitByKey[presentationKey] = SessionStore.initialSessionPageLimit
            sessionLoadStates[presentationKey] = .loaded
        } catch {
            guard sessionLoadInvocationTokens.isCurrent(invocationID, for: presentationKey) else {
                return
            }
            switch workspaceSessionLoadFailureDisposition(error) {
            case .cancelled:
                sessionLoadStates[presentationKey] = fallbackSessionLoadState(for: presentationKey)
            case .failed(let message):
                sessionLoadStates[presentationKey] = .failed(message)
            }
        }
    }

    private func sessionLoadState(for key: WorkspaceSessionPresentationKey) -> WorkspaceSessionLoadState {
        sessionLoadStates[key] ?? fallbackSessionLoadState(for: key)
    }

    private func fallbackSessionLoadState(for key: WorkspaceSessionPresentationKey) -> WorkspaceSessionLoadState {
        runtimeSessionPagesByKey[key]?.hasLoadedFirstPage == true ? .loaded : .idle
    }

}

private enum WorkspaceSessionLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isLoading: Bool {
        self == .loading
    }
}

/// 44pt 的项目胶囊：选中项展开成带名称的胶囊，其余收缩成头像圆，整行只占一条控件带。
/// 原来 316×138pt 卡片上有三个可见操作，胶囊只留得下“选中”；Git 变更、换图标和移除目录
/// 都是低频操作，收进长按菜单。分支与 Git 状态改由页面的状态行承担。
private struct WorkspaceProjectChip: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let project: AgentProject
    let profileID: String
    @ObservedObject var appearanceStore: WorkspaceAppearanceStore
    let iconStyle: WorkspaceIconStyle
    let displayedCharacter: WorkspaceCharacterIcon
    let displayedEmoji: String
    let unavailableCharacterIDs: Set<String>
    let unavailableEmoji: Set<String>
    /// 胶囊本身不再展示 Git 摘要；这里只用来决定“Git 变更”菜单项是否可用。
    let gitSummary: GitStatusResponse?
    let hasRunningSession: Bool
    let isUnavailable: Bool
    let isSelected: Bool
    /// 展开名称与选中是两件事：宽度够时所有胶囊都展开，选中仍只由亮度和字重表达。
    let showsName: Bool
    /// 距选中项的档数。只用来做透明度和图标微缩的衰减，不改变行高——
    /// 行高一旦随选中位置起伏，横向滚动时整条控件带会上下抖动。
    let distanceFromSelection: Int
    let allowsCustomization: Bool
    let tokens: ThemeTokens
    let action: () -> Void
    let onOpenGitChanges: () -> Void
    let onConfirmRemove: () -> Void

    @State private var isPresentingIconPicker = false
    @State private var isPresentingRemoveConfirmation = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                iconTile

                if showsName {
                    Text(project.name)
                        .font(themeStore.uiFont(.subheadline, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? tokens.primaryText : tokens.secondaryText)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, showsName ? 12 : 8)
            .frame(height: WorkspaceStripLayout.chipHeight)
            // 选中与未选中共用同一块磨砂：差别只在中性提亮和是否展开名称，
            // 一行里不会出现两种材质浓度。
            .background {
                WorkbenchChromeMaterial(shape: Capsule(), tokens: tokens, isTinted: isSelected)
            }
            // 波形衰减：越远离选中项越淡。只动透明度，不动行高——
            // 行高一旦随选中位置起伏，横向滚动时整条控件带会上下抖。
            .opacity(showsName ? 1 : max(0.42, 1 - Double(distanceFromSelection) * 0.16))
            .contentShape(Capsule())
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .animation(
            reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.34, dampingFraction: 0.86),
            value: showsName
        )
        .animation(
            reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.34, dampingFraction: 0.9),
            value: distanceFromSelection
        )
        .contextMenu { contextActions }
        .popover(isPresented: $isPresentingIconPicker, arrowEdge: .top) {
            iconPicker
        }
        // iPad 会把 confirmationDialog 适配成 popover；挂在胶囊本身，
        // 让系统在旋转和分栏宽度变化时按当前位置计算箭头，而不是使用整页根视图。
        .confirmationDialog(
            L10n.text("ui.remove_directory"),
            isPresented: $isPresentingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.format("ui.remove_directory_value", project.name), role: .destructive) {
                onConfirmRemove()
            }
            .accessibilityIdentifier("workspace.remove.confirm.\(project.id)")
            Button(L10n.text("ui.cancel"), role: .cancel) {
                isPresentingRemoveConfirmation = false
            }
        } message: {
            Text(L10n.text("ui.removing_a_directory_only_removes_it_from_the_workspace"))
        }
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("workspace.card.\(project.id)")
    }

    @ViewBuilder
    private var contextActions: some View {
        Button(action: onOpenGitChanges) {
            Label(L10n.text("ui.git_changes"), systemImage: "doc.text.magnifyingglass")
        }
        .disabled(gitSummary?.isRepository == false)
        .accessibilityIdentifier("workspace.card.git.\(project.id)")

        if allowsCustomization {
            Button {
                isPresentingIconPicker = true
            } label: {
                Label(
                    L10n.text("ui.workspace_icon"),
                    systemImage: iconStyle == .emoji ? "face.smiling" : "person.crop.square"
                )
            }
            .accessibilityIdentifier("workspace.card.icon.\(project.id)")
        }

        if !isSelected {
            Button(role: .destructive) {
                isPresentingRemoveConfirmation = true
            } label: {
                Label(L10n.text("ui.remove_directory"), systemImage: "xmark.circle")
            }
            .accessibilityIdentifier("workspace.remove.request.\(project.id)")
        }
    }

    @ViewBuilder
    private var iconTile: some View {
        let size = WorkspaceStripLayout.chipIconSize

        Group {
            if iconStyle.usesCharacters {
                Image(displayedCharacter.assetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(WorkspaceIconMeeGoShape())
            } else {
                let palette: [Color] = [
                    Color(red: 0.91, green: 0.63, blue: 0.48),
                    Color(red: 0.47, green: 0.67, blue: 0.78),
                    Color(red: 0.76, green: 0.64, blue: 0.42),
                    Color(red: 0.88, green: 0.72, blue: 0.34),
                    Color(red: 0.64, green: 0.70, blue: 0.48),
                    Color(red: 0.72, green: 0.53, blue: 0.72)
                ]
                let tint = palette[
                    WorkspaceAppearanceStore.tintIndex(for: displayedEmoji, count: palette.count)
                ]

                Text(displayedEmoji)
                    .font(.system(size: size * 0.58))
                    .frame(width: size, height: size)
                    .background(
                        tint.opacity(colorScheme == .dark ? 0.30 : 0.18),
                        in: WorkspaceIconMeeGoShape()
                    )
            }
        }
        .overlay {
            // 角色图统一使用暖白底；这里只提供适配明暗模式的轮廓，不再叠加随机主题色。
            WorkspaceIconMeeGoShape()
                .stroke(tokens.border.opacity(colorScheme == .dark ? 0.72 : 0.42), lineWidth: 0.75)
        }
        .overlay(alignment: .topTrailing) {
            runningIndicator
        }
        .opacity(isUnavailable ? 0.62 : 1)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var runningIndicator: some View {
        if hasRunningSession {
            // 收缩态没有名称也没有状态行，这颗点是“这个工作区有会话在跑”的唯一信号，
            // 因此用语义绿而不是原卡片上的中性灰——它不与选中态的梅紫争焦点。
            Circle()
                .fill(tokens.success)
                .frame(width: 9, height: 9)
                .overlay {
                    Circle()
                        .stroke(tokens.background, lineWidth: 1.5)
                }
                .offset(x: 2, y: -2)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var iconPicker: some View {
        if iconStyle.usesCharacters {
            WorkspaceCharacterPicker(
                project: project,
                profileID: profileID,
                appearanceStore: appearanceStore,
                style: iconStyle,
                currentCharacterID: displayedCharacter.id,
                unavailableCharacterIDs: unavailableCharacterIDs,
                tokens: tokens
            )
        } else {
            WorkspaceEmojiPicker(
                project: project,
                profileID: profileID,
                appearanceStore: appearanceStore,
                currentEmoji: displayedEmoji,
                unavailableEmoji: unavailableEmoji,
                tokens: tokens
            )
        }
    }

    private var accessibilitySummary: String {
        let statusParts = [
            isUnavailable ? L10n.text("ui.need_to_retry") : nil,
            hasRunningSession ? L10n.text("ui.running") : nil
        ].compactMap { $0 }
        let status = statusParts.isEmpty
            ? L10n.text("ui.git_status_unknown")
            : statusParts.joined(separator: ", ")
        let selected = isSelected ? L10n.text("ui.selected_b4f8bea5") : ""
        return L10n.format(
            "ui.workspace_card_summary",
            project.name,
            project.path,
            status,
            selected
        )
    }
}

/// 选中工作区的分支、Git 状态和活跃时间。原来分散在卡片的 metadataRow 里，
/// 卡片收缩成胶囊后由页面顶部的一行状态摘要统一承担。
private struct WorkspaceStatusSummary {
    let branch: String?
    let status: WorkspaceCardStatus?
    let activityText: String?

    static func make(
        gitSummary: GitStatusResponse?,
        isUnavailable: Bool,
        hasRunningSession: Bool,
        lastActivityAt: Date?,
        now: Date
    ) -> WorkspaceStatusSummary {
        WorkspaceStatusSummary(
            branch: branch(from: gitSummary),
            status: status(
                gitSummary: gitSummary,
                isUnavailable: isUnavailable,
                hasRunningSession: hasRunningSession
            ),
            activityText: activityText(lastActivityAt: lastActivityAt, now: now)
        )
    }

    private static func branch(from gitSummary: GitStatusResponse?) -> String? {
        let branch = gitSummary?.branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let branch, !branch.isEmpty {
            return branch
        }
        let head = gitSummary?.head?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let head, !head.isEmpty {
            return head
        }
        return nil
    }

    private static func status(
        gitSummary: GitStatusResponse?,
        isUnavailable: Bool,
        hasRunningSession: Bool
    ) -> WorkspaceCardStatus? {
        if isUnavailable {
            return WorkspaceCardStatus(text: L10n.text("ui.need_to_retry"), tone: .danger)
        }
        guard let gitSummary else {
            return hasRunningSession
                ? WorkspaceCardStatus(text: L10n.text("ui.running"), tone: .accent)
                : nil
        }
        guard gitSummary.isRepository else {
            return WorkspaceCardStatus(text: L10n.text("ui.not_a_git_repository"), tone: .secondary)
        }
        if !gitSummary.files.isEmpty {
            return WorkspaceCardStatus(
                text: L10n.format("ui.git_changes_count_value", gitSummary.files.count),
                tone: .warning
            )
        }

        let ahead = gitSummary.ahead ?? 0
        let behind = gitSummary.behind ?? 0
        if ahead > 0, behind > 0 {
            return WorkspaceCardStatus(text: L10n.text("ui.git_branch_diverged"), tone: .warning)
        }
        if behind > 0 {
            return WorkspaceCardStatus(text: L10n.format("ui.behind_value", behind), tone: .warning)
        }
        if ahead > 0 {
            return WorkspaceCardStatus(text: L10n.format("ui.leading_value", ahead), tone: .accent)
        }
        if gitSummary.upstream?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return WorkspaceCardStatus(text: L10n.text("ui.git_synced"), tone: .success)
        }
        return WorkspaceCardStatus(text: L10n.text("ui.clean_work_area"), tone: .success)
    }

    private static func activityText(lastActivityAt: Date?, now: Date) -> String? {
        guard let lastActivityAt else { return nil }
        let interval = max(0, now.timeIntervalSince(lastActivityAt))
        if interval < 5 * 60 {
            return L10n.text("ui.active_just_now")
        }
        if interval < 60 * 60 {
            return L10n.format("ui.minutes_ago_value", Int(interval / 60))
        }
        if interval < 24 * 60 * 60 {
            return L10n.format("ui.hours_ago_value", Int(interval / 3600))
        }
        return L10n.format("ui.days_ago_value", Int(interval / (24 * 3600)))
    }
}

private struct WorkspaceCardStatus {
    enum Tone {
        case accent
        case success
        case warning
        case danger
        case secondary
    }

    let text: String
    let tone: Tone

    /// 只有需要用户处理的状态才配着色；已同步、干净这类稳态不该在状态行里发光。
    var needsAttention: Bool {
        switch tone {
        case .warning, .danger:
            return true
        case .accent, .success, .secondary:
            return false
        }
    }

    func color(tokens: ThemeTokens) -> Color {
        switch tone {
        case .accent:
            // 运行和领先状态在主页只需可识别，不再与导航选中态争夺紫色焦点。
            return tokens.secondaryText
        case .success:
            return tokens.success
        case .warning:
            return tokens.warning
        case .danger:
            return tokens.warning
        case .secondary:
            return tokens.tertiaryText
        }
    }
}

/// 泛型视图不能持有静态存储属性，而每行重建 DateFormatter 又很贵；
/// 这两个格式化器与具体视图无关，提到文件级共享一份。
private enum WorkspaceSessionRowFormatters {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("Hm")
        return formatter
    }()

    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter
    }()
}

private struct WorkspaceDetailView<StatusLine: View>: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var compactActionFontSize: CGFloat = 12
    @State private var isLoadingMoreSessions = false

    let statusLine: StatusLine
    let recentSessions: [AgentSession]
    let unreadHistorySessionIDs: Set<SessionID>
    let sessionLoadState: WorkspaceSessionLoadState
    let hasInitialSessionContent: Bool
    let canLoadMoreSessions: Bool
    @Binding var selectedRuntime: WorkspaceSessionRuntimeChoice
    let claudeChannelAvailable: Bool
    let currentDate: () -> Date
    let onRefreshSessions: () -> Void
    let onLoadMoreSessions: () async -> Void
    let onStartSession: (WorkspaceSessionRuntimeChoice) -> Void
    let onOpenSession: (AgentSession) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                recentSessionsSection(tokens: tokens)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(tokens.background.ignoresSafeArea())
    }

    private func recentSessionsSection(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            recentSessionsHeader(tokens: tokens)

            // 工作区状态紧贴第一条会话行，与列表共用左右内边距：
            // 它是这个列表的说明文字，夹在筛选行上方会重新读成悬空的元数据。
            statusLine
                .padding(.bottom, 2)

            if sessionLoadState.isLoading, !hasInitialSessionContent {
                // 首屏窗口还没凑满：稳定显示骨架屏，避免切换时先渲染欠填的半截列表再逐批变多。
                recentSessionPlaceholders(tokens: tokens)
            } else if recentSessions.isEmpty, case .failed(let message) = sessionLoadState {
                ContentUnavailableView {
                    Label(L10n.text("ui.unable_to_load_session"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button(L10n.text("ui.reload"), action: onRefreshSessions)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(tokens.contentPanelBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if recentSessions.isEmpty {
                ContentUnavailableView(L10n.text("ui.no_sessions_yet"), systemImage: "bubble.left.and.bubble.right", description: Text(L10n.text("ui.after_a_new_session_is_created_in_this")))
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(tokens.contentPanelBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    let firstStaleIndex = WorkspaceSessionAgeBoundary.firstStaleIndex(
                        in: recentSessions,
                        excludingSessionIDs: sessionStore.pinnedSessionIDs,
                        now: currentDate()
                    )

                    ForEach(Array(recentSessions.enumerated()), id: \.element.id) { index, session in
                        if index == firstStaleIndex {
                            twelveHourBoundary(tokens: tokens)
                        } else if index > 0 {
                            Divider()
                                .overlay(tokens.border.opacity(0.62))
                                .padding(.leading, 48)
                        }

                        Button {
                            onOpenSession(session)
                        } label: {
                            recentSessionRow(session, tokens: tokens)
                        }
                        .buttonStyle(.plain)
                        .sessionRowActions(session)
                    }

                    if canLoadMoreSessions || isLoadingMoreSessions {
                        Divider()
                            .overlay(tokens.border.opacity(0.62))

                        Button {
                            guard !isLoadingMoreSessions else { return }
                            isLoadingMoreSessions = true
                            Task {
                                await onLoadMoreSessions()
                                isLoadingMoreSessions = false
                            }
                        } label: {
                            HStack(spacing: 7) {
                                if isLoadingMoreSessions {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "chevron.down")
                                        .font(themeStore.uiFont(size: compactActionFontSize, weight: .semibold))
                                }
                                Text(isLoadingMoreSessions ? L10n.text("ui.loading") : L10n.text("ui.show_more"))
                            }
                            .font(themeStore.uiFont(size: compactActionFontSize, weight: .semibold))
                            .foregroundStyle(tokens.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoadingMoreSessions)
                        .accessibilityLabel(
                            isLoadingMoreSessions
                                ? L10n.text("ui.loading")
                                : L10n.text("ui.show_more")
                        )
                        .accessibilityIdentifier("workspace.sessions.loadMore")
                    }
                }
                // 通栏行 + 发丝线，不再包一层圆角容器：会话列表是这一屏的主体，
                // 外框只会在暗色页面上再画一道与内容无关的边界。
            }
        }
    }

    /// 一行同时承担两件事：左端切运行时，右端用同一个运行时开新会话。
    /// Codex/Claude 这个维度整屏只出现一次，主操作也不再占用独立的大卡片。
    private func recentSessionsHeader(tokens: ThemeTokens) -> some View {
        HStack(spacing: 12) {
            WorkspaceRuntimePicker(
                selection: $selectedRuntime,
                claudeChannelAvailable: claudeChannelAvailable
            )

            Spacer(minLength: 8)

            newSessionButton(tokens: tokens)
        }
    }

    private func newSessionButton(tokens: ThemeTokens) -> some View {
        Button {
            // thread 创建时就绑定 runtime；这里必须把当前选择一路传到 SessionStore。
            onStartSession(selectedRuntime)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                    .font(themeStore.uiFont(.footnote, weight: .semibold))
                Text(L10n.text("ui.new_session"))
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tokens.primaryText)
            .padding(.horizontal, 14)
            .frame(minHeight: WorkbenchChromeIconMetrics.minimumHitTarget)
            .background { WorkbenchChromeMaterial(shape: Capsule(), tokens: tokens) }
            .contentShape(Capsule())
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(selectedRuntime.title)
        .accessibilityIdentifier("workspace.sessions.newSession")
    }

    private func twelveHourBoundary(tokens: ThemeTokens) -> some View {
        ZStack {
            // 直接复用普通列表分隔线的位置，只在中间留出文案缺口，
            // 避免“默认分隔线 + 分组分隔线”叠成两道横线。
            Rectangle()
                .fill(tokens.border.opacity(0.62))
                .frame(height: 0.5)

            Text(L10n.text("ui.twelve_hours_ago"))
                .font(themeStore.uiFont(.caption2, weight: .medium))
                .foregroundStyle(tokens.tertiaryText)
                .padding(.horizontal, 8)
                .background(tokens.contentPanelBackground)
                .fixedSize()
        }
        .padding(.leading, 48)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("ui.twelve_hours_ago"))
    }

    private func recentSessionPlaceholders(tokens: ThemeTokens) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tokens.elevatedSurface)
                        .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(tokens.elevatedSurface)
                            .frame(width: 180, height: 12)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(tokens.elevatedSurface)
                            .frame(width: 108, height: 9)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 62)

                if index < 2 {
                    Divider()
                        .overlay(tokens.border.opacity(0.62))
                        .padding(.leading, 48)
                }
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("ui.loading_recent_conversations"))
    }

    private func recentSessionRow(_ session: AgentSession, tokens: ThemeTokens) -> some View {
        let status = session.displayStatus(foregroundActivity: nil)
        let statusTone = recentSessionStatusColor(for: status.tone, tokens: tokens)

        return HStack(spacing: 12) {
            SessionRuntimeIcon(
                session: session,
                size: 18,
                isActive: session.isRunning
            )
                .frame(width: 34, height: 34)
                .background(
                    tokens.elevatedSurface.opacity(session.isRunning ? 0.82 : 0.54),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if sessionStore.isSessionPinned(session.id) {
                        SessionPinnedBadge(compact: true)
                    }

                    Text(session.title)
                        .font(themeStore.uiFont(.callout, weight: .medium))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if unreadHistorySessionIDs.contains(session.id) {
                        SessionUnreadIndicator()
                    }
                }

                HStack(spacing: 6) {
                    if let branch = session.gitBranchName {
                        HStack(spacing: 4) {
                            SessionBranchIcon(size: 10)
                                .foregroundStyle(tokens.tertiaryText)
                                .accessibilityHidden(true)

                            Text(branch)
                                .foregroundStyle(tokens.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(L10n.text("ui.branch")) \(branch)")
                    }

                    if shouldShowRecentSessionStatus(session, status: status) {
                        HStack(spacing: 4) {
                            if shouldShowRecentSessionSpinner(session, status: status) {
                                // 只用系统小菊花表达持续执行；待处理和失败状态依靠文字与颜色，
                                // 避免把“需要用户动作”误读为仍在自动运行。
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(statusTone)
                            }

                            Text(status.title)
                        }
                        .foregroundStyle(statusTone)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(status.title)
                    }
                }
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(sessionTimeText(for: session))
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.tertiaryText)
                .fixedSize()

            Image(systemName: "chevron.right")
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(tokens.tertiaryText)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 62)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            unreadHistorySessionIDs.contains(session.id)
                ? L10n.text("ui.unread_result")
                : ""
        )
    }

    private func shouldShowRecentSessionStatus(
        _ session: AgentSession,
        status: AgentSessionDisplayStatus
    ) -> Bool {
        session.isRunning || status.tone == .warning || status.tone == .danger
    }

    private func shouldShowRecentSessionSpinner(
        _ session: AgentSession,
        status: AgentSessionDisplayStatus
    ) -> Bool {
        session.isRunning && status.tone == .active
    }

    private func recentSessionStatusColor(
        for tone: AgentSessionStatusTone,
        tokens: ThemeTokens
    ) -> Color {
        switch tone {
        case .warning:
            return tokens.warning
        case .danger:
            return .red
        case .active, .complete, .neutral:
            // 主页的运行/完成信息属于次级元数据；紫色只留给导航与当前工作区。
            return tokens.secondaryText
        }
    }

    private func sessionTimeText(for session: AgentSession) -> String {
        guard let date = session.recencyAt ?? session.updatedAt ?? session.createdAt else { return "" }
        if Calendar.current.isDate(date, inSameDayAs: currentDate()) {
            return WorkspaceSessionRowFormatters.time.string(from: date)
        }
        return WorkspaceSessionRowFormatters.date.string(from: date)
    }

}
