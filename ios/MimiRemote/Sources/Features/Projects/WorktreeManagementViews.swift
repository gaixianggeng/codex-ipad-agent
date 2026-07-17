import SwiftUI

// Worktree 管理流程独立于项目与会话列表，降低侧边栏主体的更新和维护范围。
struct WorktreeManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    let rootProjectID: String
    @State private var pendingDelete: WorktreeListItem?
    @State private var cleanupDestination: WorktreeCleanupDestination?
    @State private var isLoadingCleanupPreview = false
    @State private var cleanupPreviewError: String?

    private var worktrees: [WorktreeListItem] {
        sessionStore.managedWorktrees(rootProjectID: rootProjectID)
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            List {
                if let message = sessionStore.worktreeErrorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(size: 13, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    ForEach(worktrees) { item in
                        WorktreeManagerRow(
                            item: item,
                            isRunning: sessionStore.hasRunningSession(in: item),
                            isBusy: sessionStore.isDeletingWorktree,
                            onOpen: {
                                Task {
                                    _ = await sessionStore.openManagedWorktree(item)
                                    dismiss()
                                }
                            },
                            onDelete: {
                                pendingDelete = item
                            }
                        )
                    }
                }
                Section {
                    Button {
                        Task { await loadCleanupPreview() }
                    } label: {
                        if isLoadingCleanupPreview {
                            Label("正在评估清理候选", systemImage: "hourglass")
                        } else {
                            Label("清理候选", systemImage: "sparkles")
                        }
                    }
                    .disabled(sessionStore.isRefreshingWorktrees || sessionStore.isDeletingWorktree || sessionStore.isPruningWorktrees || isLoadingCleanupPreview)

                    Button {
                        Task { await sessionStore.pruneMissingManagedWorktrees() }
                    } label: {
                        if sessionStore.isPruningWorktrees {
                            Label("正在清理", systemImage: "hourglass")
                        } else {
                            Label("清理丢失登记", systemImage: "checklist.unchecked")
                        }
                    }
                    .disabled(sessionStore.isRefreshingWorktrees || sessionStore.isDeletingWorktree || sessionStore.isPruningWorktrees)

                    if let cleanupPreviewError {
                        Label(cleanupPreviewError, systemImage: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(size: 13, weight: .medium))
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("“清理候选”会先按服务端固定保留策略预览，只有无 blocker 的候选可确认删除；“清理丢失登记”只移除不存在的 registry 记录。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Git Worktree")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            .overlay {
                if worktrees.isEmpty && !sessionStore.isRefreshingWorktrees {
                    ContentUnavailableView(
                        "没有 Git Worktree",
                        systemImage: "square.stack.3d.up",
                        description: Text("当前项目没有已管理的 Git Worktree。")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await sessionStore.refreshManagedWorktrees() }
                    } label: {
                        if sessionStore.isRefreshingWorktrees {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(sessionStore.isRefreshingWorktrees || sessionStore.isPruningWorktrees)
                    .accessibilityLabel("刷新 Git Worktree")
                }
            }
        }
        .task {
            await sessionStore.refreshManagedWorktrees()
        }
        .sheet(item: $cleanupDestination) { destination in
            WorktreeCleanupPreviewSheet(
                preview: destination.preview,
                rootProjectID: rootProjectID
            )
        }
        .confirmationDialog("删除 Git Worktree？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDelete = nil
                }
            }
        ), titleVisibility: .visible) {
            if let item = pendingDelete {
                Button("删除 \(item.workspace.name)", role: .destructive) {
                    let target = item
                    pendingDelete = nil
                    Task { await sessionStore.deleteManagedWorktree(target, force: false) }
                }
            }
            Button("取消", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("删除仍会由 agentd 检查运行中会话和 Git 状态；存在未提交改动时不会强制绕过保护。")
        }
    }

    @MainActor
    private func loadCleanupPreview() async {
        guard !isLoadingCleanupPreview else {
            return
        }
        isLoadingCleanupPreview = true
        cleanupPreviewError = nil
        defer { isLoadingCleanupPreview = false }
        do {
            let preview = try await sessionStore.previewManagedWorktreeCleanup()
            cleanupDestination = WorktreeCleanupDestination(preview: preview)
        } catch {
            cleanupPreviewError = userFacingCleanupError(error)
        }
    }

    private func userFacingCleanupError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 || status == 405 {
            return "当前 agentd 版本还不支持清理预览，请先升级 Mac 端 agentd。"
        }
        return error.localizedDescription
    }
}

struct WorktreeCleanupDestination: Identifiable {
    let id = UUID()
    let preview: WorktreeCleanupResponse
}

struct WorktreeCleanupPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var preview: WorktreeCleanupResponse
    @State private var selectedPaths: Set<String>
    @State private var isExecuting = false
    @State private var isShowingDestructiveConfirmation = false
    @State private var executionError: String?
    let rootProjectID: String

    init(preview: WorktreeCleanupResponse, rootProjectID: String) {
        self.rootProjectID = rootProjectID
        _preview = State(initialValue: preview)
        let candidates = Set(preview.candidatePaths)
        _selectedPaths = State(initialValue: Set(preview.worktrees.compactMap { item in
            let root = item.workspace.rootProjectID ?? item.worktree.rootProjectID
            guard root == rootProjectID,
                  item.eligible,
                  candidates.contains(item.worktree.path)
            else {
                return nil
            }
            return item.worktree.path
        }))
    }

    private var projectItems: [WorktreeCleanupItem] {
        preview.worktrees.filter { item in
            (item.workspace.rootProjectID ?? item.worktree.rootProjectID) == rootProjectID
        }
    }

    private var candidatePaths: Set<String> {
        Set(preview.candidatePaths)
    }

    private var isPlanExecutable: Bool {
        // 只有 dry-run 响应里的 plan_id 可以执行一次。执行响应即使还带着旧候选，
        // 也只能用于展示结果，不能再次选择并提交已经消费的计划。
        preview.dryRun && !preview.hasPartialFailure
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            List {
                Section("保留策略") {
                    LabeledContent("自动删除", value: preview.policy.autoDelete ? "开启" : "关闭")
                    LabeledContent("候选时间", value: "超过 \(preview.policy.candidateAfterDays) 天未使用")
                    LabeledContent("每个项目至少保留", value: "最近 \(preview.policy.keepLatestPerProject) 个")
                    LabeledContent("评估时间", value: preview.generatedAt.formatted(date: .abbreviated, time: .shortened))
                }

                Section {
                    if projectItems.isEmpty {
                        ContentUnavailableView(
                            "没有可评估的 Worktree",
                            systemImage: "checkmark.shield",
                            description: Text("当前项目没有进入清理策略评估的已管理 Worktree。")
                        )
                    } else {
                        ForEach(projectItems) { item in
                            WorktreeCleanupPreviewRow(
                                item: item,
                                isCandidate: isPlanExecutable && candidatePaths.contains(item.worktree.path),
                                isSelected: selectedPaths.contains(item.worktree.path),
                                isBusy: isExecuting
                            ) {
                                toggleSelection(item)
                            }
                        }
                    }
                } header: {
                    Text("候选与保护原因")
                } footer: {
                    Text("只有服务端 dry-run 同时标记为 eligible 的路径可以选择；有 blocker 的 Worktree 不会被提交到删除接口。")
                }

                if let executionError {
                    Section("清理结果") {
                        Label(executionError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        isShowingDestructiveConfirmation = true
                    } label: {
                        if isExecuting {
                            Label("正在重新检查并清理", systemImage: "hourglass")
                        } else {
                            Label("删除选中的 \(selectedPaths.count) 个 Worktree", systemImage: "trash")
                        }
                    }
                    .disabled(selectedPaths.isEmpty || isExecuting)
                } footer: {
                    Text("执行时 agentd 会重新计算 blocker；策略变化、运行中会话、未提交改动或未知 Git 状态都会阻止删除。")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            .navigationTitle("清理 Worktree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .disabled(isExecuting)
                }
            }
        }
        .confirmationDialog(
            "确认删除 \(selectedPaths.count) 个 Worktree？",
            isPresented: $isShowingDestructiveConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认删除", role: .destructive) {
                Task { await executeCleanup() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除对应 Git checkout。客户端不会发送 force；agentd 仍会对当前候选和所有 blocker 做最终检查。")
        }
    }

    private func toggleSelection(_ item: WorktreeCleanupItem) {
        guard isPlanExecutable,
              item.eligible,
              candidatePaths.contains(item.worktree.path),
              !isExecuting
        else {
            return
        }
        if selectedPaths.contains(item.worktree.path) {
            selectedPaths.remove(item.worktree.path)
        } else {
            selectedPaths.insert(item.worktree.path)
        }
        executionError = nil
    }

    @MainActor
    private func executeCleanup() async {
        guard !isExecuting else {
            return
        }
        isExecuting = true
        executionError = nil
        defer { isExecuting = false }
        do {
            let response = try await sessionStore.cleanupManagedWorktrees(paths: selectedPaths, preview: preview)
            if let partialFailureMessage = response.partialFailureMessage {
                // plan_id 在执行开始后即失效；部分成功时保留结果页，但清空选择，
                // 要求用户关闭后重新 dry-run，不能误用旧计划重试剩余路径。
                preview = response
                selectedPaths = []
                executionError = partialFailureMessage
                return
            }
            guard !response.deletedPaths.isEmpty else {
                preview = response
                selectedPaths = []
                executionError = "agentd 重新检查后没有删除任何 Worktree，请关闭后重新生成预览。"
                return
            }
            dismiss()
        } catch {
            executionError = error.localizedDescription
        }
    }
}

struct WorktreeCleanupPreviewRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    let item: WorktreeCleanupItem
    let isCandidate: Bool
    let isSelected: Bool
    let isBusy: Bool
    let onToggle: () -> Void

    private var isSelectable: Bool {
        item.eligible && isCandidate
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelectable ? (isSelected ? "checkmark.circle.fill" : "circle") : "lock.shield.fill")
                    .foregroundStyle(isSelectable ? tokens.accent : tokens.secondaryText)
                    .font(themeStore.uiFont(size: 19, weight: .semibold))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.workspace.name)
                        .font(themeStore.uiFont(size: 15, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(item.worktree.path)
                        .font(themeStore.uiFont(size: 11))
                        .foregroundStyle(tokens.tertiaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    cleanupDates
                    if isSelectable {
                        Label("符合清理策略", systemImage: "checkmark.shield")
                            .font(themeStore.uiFont(size: 12, weight: .medium))
                            .foregroundStyle(tokens.success)
                    } else {
                        blockers
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable || isBusy)
        .accessibilityLabel(accessibilityLabel)
    }

    private var cleanupDates: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let createdAt = item.createdAt {
                Text("创建：\(createdAt.formatted(date: .abbreviated, time: .omitted))")
            }
            if let lastUsedAt = item.lastUsedAt {
                Text("最近使用：\(lastUsedAt.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .font(themeStore.uiFont(size: 11))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var blockers: some View {
        if item.blockers.isEmpty {
            Label("服务端未判定为可清理", systemImage: "shield")
                .font(themeStore.uiFont(size: 12, weight: .medium))
                .foregroundStyle(.orange)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(item.blockers) { blocker in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(blocker.message)
                            .font(themeStore.uiFont(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                        Text(blocker.code)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var accessibilityLabel: String {
        if isSelectable {
            return "\(item.workspace.name)，可清理，\(isSelected ? "已选择" : "未选择")"
        }
        let reasons = item.blockers.map(\.message).joined(separator: "，")
        return "\(item.workspace.name)，不可清理，\(reasons)"
    }
}

struct CreateWorktreeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    let project: AgentProject
    @State private var name = ""
    @State private var base = ""
    @State private var branch = ""
    @State private var didApplyDefaultBase = false

    private var canCreate: Bool {
        !sessionStore.isCreatingWorktree
    }

    private var branchList: WorktreeBranchListResponse? {
        sessionStore.worktreeBranches(path: project.path)
    }

    private var baseBranchItems: [WorktreeBranchItem] {
        branchList?.branches ?? []
    }

    private var branchErrorMessage: String? {
        sessionStore.worktreeBranchError(path: project.path)
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            Form {
                Section {
                    LabeledContent("项目") {
                        Text(project.name)
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(1)
                    }
                    TextField("名称", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack(spacing: 8) {
                        TextField("Base", text: $base)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if sessionStore.isRefreshingWorktreeBranches && baseBranchItems.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                        } else if !baseBranchItems.isEmpty {
                            Menu {
                                ForEach(baseBranchItems) { item in
                                    Button {
                                        base = item.name
                                        didApplyDefaultBase = true
                                    } label: {
                                        Label(branchMenuTitle(item), systemImage: branchIconName(item))
                                    }
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                                    .foregroundStyle(tokens.secondaryText)
                                    .frame(width: 28, height: 28)
                            }
                            .accessibilityLabel("选择 Base")
                        }
                    }
                    TextField("分支", text: $branch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let message = branchErrorMessage, !message.isEmpty {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(size: 13, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }

                if let message = sessionStore.errorMessage, !message.isEmpty {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(size: 13, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            .navigationTitle("新建 Git Worktree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            let opened = await sessionStore.createWorktreeAndOpen(
                                project: project,
                                name: normalizedOptional(name),
                                base: normalizedOptional(base),
                                branch: normalizedOptional(branch)
                            )
                            if opened {
                                dismiss()
                            }
                        }
                    } label: {
                        if sessionStore.isCreatingWorktree {
                            ProgressView()
                        } else {
                            Text("创建")
                        }
                    }
                    .disabled(!canCreate)
                }
            }
            .task(id: project.path) {
                await sessionStore.refreshWorktreeBranches(path: project.path)
                applyDefaultBaseIfNeeded()
            }
            .onChange(of: branchList?.defaultBase ?? "") { _, _ in
                applyDefaultBaseIfNeeded()
            }
        }
    }

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func applyDefaultBaseIfNeeded() {
        guard !didApplyDefaultBase,
              normalizedOptional(base) == nil,
              let defaultBase = branchList?.defaultBase,
              !defaultBase.isEmpty
        else {
            return
        }
        base = defaultBase
        didApplyDefaultBase = true
    }

    private func branchMenuTitle(_ item: WorktreeBranchItem) -> String {
        if item.isCurrent {
            return "\(item.name) · 当前"
        }
        if item.isDefault {
            return "\(item.name) · 默认"
        }
        return item.name
    }

    private func branchIconName(_ item: WorktreeBranchItem) -> String {
        item.kind == "remote" ? "arrow.down.circle" : "point.topleft.down.curvedto.point.bottomright.up"
    }
}

struct WorktreeManagerRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    let item: WorktreeListItem
    let isRunning: Bool
    let isBusy: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(tokens.accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.workspace.name)
                        .font(themeStore.uiFont(size: 15, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(1)
                    Text(item.worktree.rootProjectName)
                        .font(themeStore.uiFont(size: 12, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isRunning {
                    Text("运行中")
                        .font(themeStore.uiFont(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.primaryAction)
                }
            }

            Text(item.workspace.path)
                .font(themeStore.uiFont(size: 12, weight: .regular))
                .foregroundStyle(tokens.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(item.worktree.branch ?? item.worktree.base, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(themeStore.uiFont(size: 11, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                    Label("base \(item.worktree.base)", systemImage: "arrow.triangle.branch")
                        .font(themeStore.uiFont(size: 11, weight: .regular))
                        .foregroundStyle(tokens.tertiaryText)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: onOpen) {
                    Label("打开", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(isRunning || isBusy)
            }

            if !worktreeStatusItems.isEmpty {
                HStack(spacing: 6) {
                    ForEach(worktreeStatusItems, id: \.self) { item in
                        Text(item)
                            .font(themeStore.uiFont(size: 10, weight: .semibold))
                            .foregroundStyle(tokens.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(tokens.surface, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var worktreeStatusItems: [String] {
        var items: [String] = []
        if item.worktree.gitState == "unknown" {
            items.append("Git 状态未知")
        } else if item.worktree.dirty || item.worktree.gitState == "dirty" {
            items.append("未提交")
        }
        if item.worktree.ahead > 0 {
            items.append("领先 \(item.worktree.ahead)")
        }
        if item.worktree.behind > 0 {
            items.append("落后 \(item.worktree.behind)")
        }
        if let upstream = item.worktree.upstream?.trimmingCharacters(in: .whitespacesAndNewlines), !upstream.isEmpty {
            items.append(upstream)
        }
        return items
    }
}

struct SidebarListRowStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

extension View {
    func sidebarListRow() -> some View {
        modifier(SidebarListRowStyle())
    }
}
