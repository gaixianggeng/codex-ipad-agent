import SwiftUI

struct DiffPanelView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var conversationStore: ConversationStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var pendingRevertFile: GitFileStatus?
    @State private var pendingRevertHunkPatch: String?
    @State private var pendingRevertHunkTitle = ""
    @State private var isShowingRevertConfirmation = false
    @State private var isShowingRevertHunkConfirmation = false
    @State private var commitMessage = ""
    @State private var pullRequestTitle = ""
    @State private var pullRequestBody = ""
    @State private var reviewComments: [GitReviewComment] = []

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Git 变更")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(sessionStore.selectedGitStatusPath ?? "未选择工作区")
                        .font(themeStore.codeFont(.caption2))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if gitControlIsWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task {
                        await sessionStore.refreshSelectedGitStatus()
                        await sessionStore.refreshSelectedPullRequestStatus()
                    }
                } label: {
                    Label("刷新 Git 状态", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(sessionStore.selectedGitStatusPath == nil || gitControlIsWorking)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Rectangle()
                .fill(tokens.border)
                .frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    gitStatusContent(tokens: tokens)

                    if !fileChangeItems.isEmpty {
                        Text("运行时摘要")
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                            .foregroundStyle(tokens.tertiaryText)
                            .padding(.top, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(fileChangeItems) { item in
                        InspectorSummaryCard(
                            symbolName: "doc.text.magnifyingglass",
                            title: item.title,
                            subtitle: item.displaySubtitle,
                            tint: tokens.accent
                        )
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .task(id: sessionStore.selectedGitStatusPath) {
            await sessionStore.refreshSelectedGitStatus()
        }
        .confirmationDialog("撤销工作区改动？", isPresented: $isShowingRevertConfirmation, titleVisibility: .visible) {
            if let file = pendingRevertFile {
                Button("撤销 \(file.path)", role: .destructive) {
                    let path = file.path
                    pendingRevertFile = nil
                    Task { await sessionStore.performSelectedGitAction(.revert, files: [path]) }
                }
            }
            Button("取消", role: .cancel) {
                pendingRevertFile = nil
            }
        } message: {
            Text("这会丢弃该已跟踪文件的未暂存改动，未跟踪文件不会被删除。")
        }
        .confirmationDialog("撤销这个 hunk？", isPresented: $isShowingRevertHunkConfirmation, titleVisibility: .visible) {
            if let patch = pendingRevertHunkPatch {
                Button("撤销 hunk", role: .destructive) {
                    pendingRevertHunkPatch = nil
                    pendingRevertHunkTitle = ""
                    Task { await sessionStore.performSelectedGitPatchAction(.revertPatch, patch: patch) }
                }
            }
            Button("取消", role: .cancel) {
                pendingRevertHunkPatch = nil
                pendingRevertHunkTitle = ""
            }
        } message: {
            Text(pendingRevertHunkTitle)
        }
    }

    @ViewBuilder
    private func gitStatusContent(tokens: ThemeTokens) -> some View {
        if let error = sessionStore.selectedGitStatusErrorMessage {
            InspectorSummaryCard(
                symbolName: "exclamationmark.triangle",
                title: "Git 状态不可用",
                subtitle: error,
                tint: tokens.warning,
                lineLimit: nil
            )
        } else {
            if let actionError = sessionStore.selectedGitActionErrorMessage {
                InspectorSummaryCard(
                    symbolName: "exclamationmark.triangle",
                    title: "Git 动作失败",
                    subtitle: actionError,
                    tint: tokens.warning,
                    lineLimit: nil
                )
            }

            if let status = sessionStore.selectedGitStatus {
                if !status.isRepository {
                    ContentUnavailableView("当前工作区不是 Git 仓库", systemImage: "folder")
                        .font(themeStore.uiFont(.caption))
                        .padding(.top, 48)
                } else if !status.hasChanges && fileChangeItems.isEmpty {
                    ContentUnavailableView("暂无文件变更", systemImage: "doc.text.magnifyingglass")
                        .font(themeStore.uiFont(.caption))
                        .padding(.top, 48)
                } else {
                    InspectorSummaryCard(
                        symbolName: "checklist",
                        title: gitSummaryTitle(status),
                        subtitle: gitSummarySubtitle(status),
                        tint: tokens.accent,
                        lineLimit: nil
                    )
                    GitPublishBox(
                        title: $pullRequestTitle,
                        prBody: $pullRequestBody,
                        pullRequestURL: sessionStore.selectedPullRequestURL,
                        pullRequestStatus: sessionStore.selectedPullRequestStatus,
                        pullRequestStatusError: sessionStore.selectedPullRequestStatusErrorMessage,
                        isRefreshingPullRequestStatus: sessionStore.isRefreshingPullRequestStatus,
                        isWorking: gitControlIsWorking,
                        canPublish: nonEmpty(status.branch) != nil,
                        onPush: {
                            Task { await sessionStore.pushSelectedGitBranch() }
                        },
                        onCreatePullRequest: {
                            let title = pullRequestTitle
                            let body = pullRequestBody
                            Task { await sessionStore.createSelectedPullRequest(title: title, body: body, draft: true) }
                        },
                        onRefreshPullRequestStatus: {
                            Task { await sessionStore.refreshSelectedPullRequestStatus() }
                        },
                        reviewCommentCount: selectedReviewComments.count,
                        onAppendReviewNotes: {
                            appendReviewNotesToPullRequestBody()
                        }
                    )
                    if !status.files.isEmpty {
                        GitFileStatusList(
                            files: status.files,
                            isWorking: gitControlIsWorking,
                            onStage: { file in
                                Task { await sessionStore.performSelectedGitAction(.stage, files: [file.path]) }
                            },
                            onUnstage: { file in
                                Task { await sessionStore.performSelectedGitAction(.unstage, files: [file.path]) }
                        },
                        onRevert: { file in
                            pendingRevertFile = file
                            isShowingRevertConfirmation = true
                        }
                    )
                }
                    if let diffStat = nonEmpty(status.diffStat) {
                        InspectorSummaryCard(
                            symbolName: "chart.bar.doc.horizontal",
                            title: "Diff 统计",
                            subtitle: diffStat,
                            tint: tokens.accent,
                            lineLimit: nil
                        )
                    }
                    if let stagedDiff = nonEmpty(status.stagedDiff) {
                        GitCommitBox(
                            message: $commitMessage,
                            isWorking: gitControlIsWorking,
                            onCommit: {
                                let message = commitMessage
                                Task {
                                    await sessionStore.commitSelectedGitChanges(message: message)
                                    if sessionStore.selectedGitActionErrorMessage == nil {
                                        commitMessage = ""
                                    }
                                }
                            }
                        )
                        GitDiffBlock(
                            title: "已暂存 diff",
                            text: stagedDiff,
                            isWorking: gitControlIsWorking,
                            primaryActionTitle: "取消暂存 hunk",
                            primaryActionSystemImage: "minus.square",
                            primaryActionTint: tokens.accent,
                            onPrimaryAction: { hunk in
                                Task { await sessionStore.performSelectedGitPatchAction(.unstagePatch, patch: hunk.patch) }
                            },
                            reviewComments: selectedReviewComments,
                            onAddReviewComment: addReviewComment
                        )
                    }
                    if let unstagedDiff = nonEmpty(status.unstagedDiff) {
                        GitDiffBlock(
                            title: "未暂存 diff",
                            text: unstagedDiff,
                            isWorking: gitControlIsWorking,
                            primaryActionTitle: "暂存 hunk",
                            primaryActionSystemImage: "plus.square",
                            primaryActionTint: tokens.accent,
                            onPrimaryAction: { hunk in
                                Task { await sessionStore.performSelectedGitPatchAction(.stagePatch, patch: hunk.patch) }
                            },
                            destructiveActionTitle: "撤销 hunk",
                            destructiveActionSystemImage: "arrow.counterclockwise",
                            destructiveActionTint: tokens.warning,
                            onDestructiveAction: { hunk in
                                pendingRevertHunkPatch = hunk.patch
                                pendingRevertHunkTitle = hunk.title
                                isShowingRevertHunkConfirmation = true
                            },
                            reviewComments: selectedReviewComments,
                            onAddReviewComment: addReviewComment
                        )
                    }
                    if status.truncated == true, let note = status.truncatedNote {
                        InspectorSummaryCard(
                            symbolName: "scissors",
                            title: "输出已截断",
                            subtitle: note,
                            tint: tokens.warning,
                            lineLimit: nil
                        )
                    }
                }
            } else if sessionStore.isRefreshingGitStatus {
                ProgressView("正在读取 Git 状态")
                    .font(themeStore.uiFont(.caption))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
            } else {
                ContentUnavailableView("暂无 Git 状态", systemImage: "arrow.clockwise")
                    .font(themeStore.uiFont(.caption))
                    .padding(.top, 48)
            }
        }
    }

    private var fileChangeItems: [DiffPanelItem] {
        let messages = conversationStore
            .messages(for: sessionStore.selectedSessionID)
            .filter { $0.kind == .fileChangeSummary }
            .suffix(80)

        return DiffPanelItem.items(from: messages)
    }

    private var gitControlIsWorking: Bool {
        sessionStore.isRefreshingGitStatus
            || sessionStore.isRunningGitAction
            || sessionStore.isCommittingGitChanges
            || sessionStore.isPushingGitBranch
            || sessionStore.isCreatingPullRequest
            || sessionStore.isRefreshingPullRequestStatus
    }

    private var selectedReviewComments: [GitReviewComment] {
        let path = sessionStore.selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reviewComments
            .filter { $0.workspacePath == path }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func addReviewComment(hunk: GitPatchHunk, body: String) {
        let workspacePath = sessionStore.selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspacePath.isEmpty, !text.isEmpty else {
            return
        }
        reviewComments.append(GitReviewComment(
            workspacePath: workspacePath,
            hunkKey: hunk.commentKey,
            hunkTitle: hunk.title,
            body: text,
            createdAt: Date()
        ))
    }

    private func appendReviewNotesToPullRequestBody() {
        let notes = reviewNotesMarkdown()
        guard !notes.isEmpty else {
            return
        }
        let trimmedBody = pullRequestBody.trimmingCharacters(in: .whitespacesAndNewlines)
        pullRequestBody = trimmedBody.isEmpty ? notes : "\(trimmedBody)\n\n\(notes)"
    }

    private func reviewNotesMarkdown() -> String {
        let comments = selectedReviewComments
        guard !comments.isEmpty else {
            return ""
        }
        let items = comments.map { comment in
            let body = comment.body
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return "- `\(comment.hunkTitle)`: \(body)"
        }
        return "### 审查备注\n\n" + items.joined(separator: "\n")
    }

    private func gitSummaryTitle(_ status: GitStatusResponse) -> String {
        if let branch = nonEmpty(status.branch) {
            return "Git 状态 · \(branch)"
        }
        if let head = nonEmpty(status.head) {
            return "Git 状态 · \(head)"
        }
        return "Git 状态"
    }

    private func gitSummarySubtitle(_ status: GitStatusResponse) -> String {
        if let statusText = nonEmpty(status.statusText) {
            return statusText
        }
        return "工作区干净"
    }

    private func nonEmpty(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}

private struct GitReviewComment: Identifiable, Hashable {
    let id = UUID()
    let workspacePath: String
    let hunkKey: String
    let hunkTitle: String
    let body: String
    let createdAt: Date
}

struct DiffPanelItem: Identifiable {
    let fileKey: String
    var latestContent = ""
    var latestCreatedAt = Date.distantPast
    var count = 0
    var wasCollapsed = false

    var id: String { fileKey }

    var title: String {
        count > 1 ? "文件变更 x\(count)" : "文件变更"
    }

    var displaySubtitle: String {
        let suffix = wasCollapsed ? "\n\n已折叠长 diff，仅展示尾部摘要。" : ""
        return latestContent + suffix
    }

    mutating func merge(_ message: ConversationMessage) {
        count += 1
        if message.createdAt >= latestCreatedAt {
            latestCreatedAt = message.createdAt
            let collapsed = Self.collapsedContent(message.content)
            latestContent = collapsed.content
            wasCollapsed = collapsed.wasCollapsed
        }
    }

    static func fileKey(from message: ConversationMessage) -> String {
        let content = message.content
            .replacingOccurrences(of: "文件变更：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstToken = content.split(separator: " ", maxSplits: 1).first.map(String.init)
        return firstToken?.isEmpty == false ? firstToken! : message.stableID ?? message.id.uuidString
    }

    static func items<S: Sequence>(from messages: S) -> [DiffPanelItem] where S.Element == ConversationMessage {
        var grouped: [String: DiffPanelItem] = [:]
        for message in messages {
            let key = DiffPanelItem.fileKey(from: message)
            grouped[key, default: DiffPanelItem(fileKey: key)].merge(message)
        }

        return grouped.values
            .sorted { $0.latestCreatedAt > $1.latestCreatedAt }
            .prefix(50)
            .map { $0 }
    }

    static func collapsedContent(_ content: String) -> (content: String, wasCollapsed: Bool) {
        let maxCharacters = 1_200
        guard content.count > maxCharacters else {
            return (content, false)
        }
        return (String(content.suffix(maxCharacters)), true)
    }
}

struct InspectorSummaryCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let symbolName: String
    let title: String
    let subtitle: String
    let tint: Color
    let lineLimit: Int?

    init(symbolName: String, title: String, subtitle: String, tint: Color, lineLimit: Int? = 4) {
        self.symbolName = symbolName
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.lineLimit = lineLimit
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbolName)
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(tint.opacity(0.18), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(subtitle)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(lineLimit)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.elevatedSurface.opacity(0.88), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.72), lineWidth: 1)
        }
    }

}

private struct GitFileStatusList: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let files: [GitFileStatus]
    let isWorking: Bool
    let onStage: (GitFileStatus) -> Void
    let onUnstage: (GitFileStatus) -> Void
    let onRevert: (GitFileStatus) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            Label("文件", systemImage: "doc.on.doc")
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.primaryText)

            VStack(spacing: 0) {
                ForEach(files) { file in
                    GitFileStatusRow(
                        file: file,
                        isWorking: isWorking,
                        onStage: onStage,
                        onUnstage: onUnstage,
                        onRevert: onRevert
                    )
                    if file.id != files.last?.id {
                        Rectangle()
                            .fill(tokens.border)
                            .frame(height: 1)
                    }
                }
            }
            .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tokens.border, lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GitFileStatusRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let file: GitFileStatus
    let isWorking: Bool
    let onStage: (GitFileStatus) -> Void
    let onUnstage: (GitFileStatus) -> Void
    let onRevert: (GitFileStatus) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 8) {
            Text(file.displayCode)
                .font(themeStore.codeFont(.caption2, weight: .semibold))
                .foregroundStyle(tokens.accent)
                .frame(width: 28, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.path)
                    .font(themeStore.codeFont(.caption2))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusLabel)
                    .font(themeStore.uiFont(.caption2))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                if file.unstaged || file.untracked {
                    gitActionButton(title: "暂存", systemImage: "plus.square", tint: tokens.accent) {
                        onStage(file)
                    }
                }
                if file.staged {
                    gitActionButton(title: "取消暂存", systemImage: "minus.square", tint: tokens.accent) {
                        onUnstage(file)
                    }
                }
                if file.unstaged && !file.untracked {
                    gitActionButton(title: "撤销", systemImage: "arrow.counterclockwise", tint: tokens.warning) {
                        onRevert(file)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var statusLabel: String {
        if file.untracked {
            return "未跟踪"
        }
        if file.staged && file.unstaged {
            return "已暂存，还有工作区改动"
        }
        if file.staged {
            return "已暂存"
        }
        if file.unstaged {
            return "工作区改动"
        }
        return "无变更"
    }

    private func gitActionButton(title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(tint)
        .disabled(isWorking)
        .help(title)
    }
}

private struct GitCommitBox: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Binding var message: String
    let isWorking: Bool
    let onCommit: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let canCommit = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking

        HStack(alignment: .top, spacing: 8) {
            TextField("提交说明", text: $message, axis: .vertical)
                .font(themeStore.uiFont(.caption))
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .padding(9)
                .background(tokens.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tokens.border, lineWidth: 1)
                }

            Button(action: onCommit) {
                Label("提交", systemImage: "checkmark.circle")
                    .labelStyle(.iconOnly)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(canCommit ? tokens.success : tokens.tertiaryText)
            .disabled(!canCommit)
            .help("提交已暂存变更")
        }
        .padding(10)
        .background(tokens.success.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.success.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct GitPublishBox: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Binding var title: String
    @Binding var prBody: String
    let pullRequestURL: String?
    let pullRequestStatus: GitPullRequestStatusResponse?
    let pullRequestStatusError: String?
    let isRefreshingPullRequestStatus: Bool
    let isWorking: Bool
    let canPublish: Bool
    let onPush: () -> Void
    let onCreatePullRequest: () -> Void
    let onRefreshPullRequestStatus: () -> Void
    let reviewCommentCount: Int
    let onAppendReviewNotes: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let canCreatePR = canPublish && !isWorking && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("发布分支", systemImage: "arrow.up.circle")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Spacer()
                if isRefreshingPullRequestStatus {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(action: onRefreshPullRequestStatus) {
                    Label("刷新 PR 状态", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.iconOnly)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(canPublish && !isWorking ? tokens.accent : tokens.tertiaryText)
                .disabled(!canPublish || isWorking)
                .help("刷新 PR 状态")
                Button(action: onPush) {
                    Label("Push", systemImage: "arrow.up.circle")
                        .labelStyle(.iconOnly)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(canPublish && !isWorking ? tokens.accent : tokens.tertiaryText)
                .disabled(!canPublish || isWorking)
                .help("Push 当前分支")
            }

            TextField("PR 标题", text: $title)
                .font(themeStore.uiFont(.caption))
                .textFieldStyle(.plain)
                .padding(9)
                .background(tokens.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tokens.border, lineWidth: 1)
                }

            TextField("PR 描述", text: $prBody, axis: .vertical)
                .font(themeStore.uiFont(.caption))
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .padding(9)
                .background(tokens.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tokens.border, lineWidth: 1)
                }

            HStack(spacing: 8) {
                Button(action: onCreatePullRequest) {
                    Label("创建草稿 PR", systemImage: "arrow.triangle.pull")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(canCreatePR ? tokens.success : tokens.tertiaryText)
                .disabled(!canCreatePR)
                Spacer()
                if let pullRequestURL, let url = URL(string: pullRequestURL) {
                    Link("打开 PR", destination: url)
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                }
            }
            if reviewCommentCount > 0 {
                Button(action: onAppendReviewNotes) {
                    Label("追加 \(reviewCommentCount) 条审查备注", systemImage: "text.badge.plus")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(tokens.accent)
            }

            pullRequestStatusView(tokens: tokens)
        }
        .padding(10)
        .background(tokens.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.accent.opacity(0.22), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func pullRequestStatusView(tokens: ThemeTokens) -> some View {
        if let status = pullRequestStatus {
            if status.exists {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: status.isDraft ? "doc.badge.clock" : "arrow.triangle.pull")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(status.isDraft ? tokens.warning : tokens.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prStatusTitle(status))
                            .font(themeStore.uiFont(.caption2, weight: .semibold))
                            .foregroundStyle(tokens.primaryText)
                            .lineLimit(1)
                        Text(prStatusSubtitle(status))
                            .font(themeStore.codeFont(.caption2))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.top, 2)
            } else {
                Text("当前分支暂无 PR")
                    .font(themeStore.uiFont(.caption2))
                    .foregroundStyle(tokens.secondaryText)
            }
        } else if let error = pullRequestStatusError?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            Text("PR 状态不可用：\(error)")
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.warning)
                .lineLimit(2)
        }
    }

    private func prStatusTitle(_ status: GitPullRequestStatusResponse) -> String {
        let number = status.number.map { "#\($0)" } ?? "PR"
        let state = status.state?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = status.isDraft ? "Draft" : (state?.isEmpty == false ? state! : "Open")
        if let title = status.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return "\(number) · \(kind) · \(title)"
        }
        return "\(number) · \(kind)"
    }

    private func prStatusSubtitle(_ status: GitPullRequestStatusResponse) -> String {
        var parts: [String] = []
        if let head = status.headRefName?.trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty,
           let base = status.baseRefName?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
            parts.append("\(head) -> \(base)")
        } else if !status.branch.isEmpty {
            parts.append(status.branch)
        }
        if let review = status.reviewDecision?.trimmingCharacters(in: .whitespacesAndNewlines), !review.isEmpty {
            parts.append(review)
        }
        if let merge = status.mergeStateStatus?.trimmingCharacters(in: .whitespacesAndNewlines), !merge.isEmpty {
            parts.append(merge)
        }
        return parts.isEmpty ? "状态已读取" : parts.joined(separator: " · ")
    }
}

private struct GitDiffBlock: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let text: String
    let isWorking: Bool
    let primaryActionTitle: String?
    let primaryActionSystemImage: String
    let primaryActionTint: Color?
    let onPrimaryAction: ((GitPatchHunk) -> Void)?
    let destructiveActionTitle: String?
    let destructiveActionSystemImage: String
    let destructiveActionTint: Color?
    let onDestructiveAction: ((GitPatchHunk) -> Void)?
    let reviewComments: [GitReviewComment]
    let onAddReviewComment: ((GitPatchHunk, String) -> Void)?

    init(
        title: String,
        text: String,
        isWorking: Bool = false,
        primaryActionTitle: String? = nil,
        primaryActionSystemImage: String = "plus.square",
        primaryActionTint: Color? = nil,
        onPrimaryAction: ((GitPatchHunk) -> Void)? = nil,
        destructiveActionTitle: String? = nil,
        destructiveActionSystemImage: String = "arrow.counterclockwise",
        destructiveActionTint: Color? = nil,
        onDestructiveAction: ((GitPatchHunk) -> Void)? = nil,
        reviewComments: [GitReviewComment] = [],
        onAddReviewComment: ((GitPatchHunk, String) -> Void)? = nil
    ) {
        self.title = title
        self.text = text
        self.isWorking = isWorking
        self.primaryActionTitle = primaryActionTitle
        self.primaryActionSystemImage = primaryActionSystemImage
        self.primaryActionTint = primaryActionTint
        self.onPrimaryAction = onPrimaryAction
        self.destructiveActionTitle = destructiveActionTitle
        self.destructiveActionSystemImage = destructiveActionSystemImage
        self.destructiveActionTint = destructiveActionTint
        self.onDestructiveAction = onDestructiveAction
        self.reviewComments = reviewComments
        self.onAddReviewComment = onAddReviewComment
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let hunks = GitPatchHunk.hunks(from: text)

        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "doc.text")
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.primaryText)

            if hunks.isEmpty {
                rawDiffView(tokens: tokens)
            } else {
                VStack(spacing: 8) {
                    ForEach(hunks) { hunk in
                        GitPatchHunkRow(
                            hunk: hunk,
                            isWorking: isWorking,
                            primaryActionTitle: primaryActionTitle,
                            primaryActionSystemImage: primaryActionSystemImage,
                            primaryActionTint: primaryActionTint ?? tokens.accent,
                            onPrimaryAction: onPrimaryAction,
                            destructiveActionTitle: destructiveActionTitle,
                            destructiveActionSystemImage: destructiveActionSystemImage,
                            destructiveActionTint: destructiveActionTint ?? tokens.warning,
                            onDestructiveAction: onDestructiveAction,
                            reviewComments: reviewComments.filter { $0.hunkKey == hunk.commentKey },
                            onAddReviewComment: onAddReviewComment
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rawDiffView(tokens: ThemeTokens) -> some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(themeStore.codeFont(.caption2))
                .foregroundStyle(tokens.primaryText)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.border, lineWidth: 1)
        }
    }
}

private struct GitPatchHunkRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let hunk: GitPatchHunk
    let isWorking: Bool
    let primaryActionTitle: String?
    let primaryActionSystemImage: String
    let primaryActionTint: Color
    let onPrimaryAction: ((GitPatchHunk) -> Void)?
    let destructiveActionTitle: String?
    let destructiveActionSystemImage: String
    let destructiveActionTint: Color
    let onDestructiveAction: ((GitPatchHunk) -> Void)?
    let reviewComments: [GitReviewComment]
    let onAddReviewComment: ((GitPatchHunk, String) -> Void)?
    @State private var isAddingReviewComment = false
    @State private var reviewCommentDraft = ""

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(hunk.title, systemImage: "line.3.horizontal.decrease")
                    .font(themeStore.uiFont(.caption2, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button {
                    isAddingReviewComment.toggle()
                } label: {
                    Label(reviewComments.isEmpty ? "添加审查备注" : "审查备注 \(reviewComments.count)", systemImage: reviewComments.isEmpty ? "text.badge.plus" : "text.bubble")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(reviewComments.isEmpty ? tokens.accent : tokens.success)
                .help(reviewComments.isEmpty ? "添加审查备注" : "查看/添加审查备注")

                if let primaryActionTitle, let onPrimaryAction {
                    hunkActionButton(
                        title: primaryActionTitle,
                        systemImage: primaryActionSystemImage,
                        tint: primaryActionTint
                    ) {
                        onPrimaryAction(hunk)
                    }
                }
                if let destructiveActionTitle, let onDestructiveAction {
                    hunkActionButton(
                        title: destructiveActionTitle,
                        systemImage: destructiveActionSystemImage,
                        tint: destructiveActionTint
                    ) {
                        onDestructiveAction(hunk)
                    }
                }
            }

            ScrollView(.horizontal) {
                Text(hunk.preview)
                    .font(themeStore.codeFont(.caption2))
                    .foregroundStyle(tokens.primaryText)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !reviewComments.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(reviewComments) { comment in
                        Label(comment.body, systemImage: "text.bubble")
                            .font(themeStore.uiFont(.caption2))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(tokens.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if isAddingReviewComment {
                HStack(alignment: .top, spacing: 8) {
                    TextField("审查备注", text: $reviewCommentDraft, axis: .vertical)
                        .font(themeStore.uiFont(.caption))
                        .textFieldStyle(.plain)
                        .lineLimit(2...4)
                        .padding(8)
                        .background(tokens.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(tokens.border, lineWidth: 1)
                        }
                    Button {
                        let text = reviewCommentDraft
                        onAddReviewComment?(hunk, text)
                        reviewCommentDraft = ""
                        isAddingReviewComment = false
                    } label: {
                        Label("保存备注", systemImage: "checkmark.circle")
                            .labelStyle(.iconOnly)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(reviewCommentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tokens.tertiaryText : tokens.success)
                    .disabled(reviewCommentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(8)
        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.border, lineWidth: 1)
        }
    }

    private func hunkActionButton(title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(tint)
        .disabled(isWorking)
        .help(title)
    }
}

private struct GitPatchHunk: Identifiable, Hashable {
    let id: String
    let title: String
    let patch: String
    let preview: String

    var commentKey: String {
        patch
    }

    static func hunks(from diff: String) -> [GitPatchHunk] {
        var text = diff.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        if !text.hasSuffix("\n") {
            text += "\n"
        }

        var fileHeader: [String] = []
        var currentHunk: [String] = []
        var result: [GitPatchHunk] = []

        func finishHunk() {
            guard !fileHeader.isEmpty, !currentHunk.isEmpty else {
                currentHunk = []
                return
            }
            // 每个按钮提交给后端的是完整单 hunk patch：文件头 + 当前 hunk。
            let patch = (fileHeader + currentHunk).joined()
            let hunkHeader = currentHunk.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "hunk"
            let filePath = displayPath(from: fileHeader)
            let title = filePath.isEmpty ? hunkHeader : "\(filePath) · \(hunkHeader)"
            let preview = currentHunk.joined()
            result.append(GitPatchHunk(id: "\(result.count)-\(title)", title: title, patch: patch, preview: preview))
            currentHunk = []
        }

        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map({ String($0) + "\n" }) {
            if line.hasPrefix("diff --git ") {
                finishHunk()
                fileHeader = [line]
                continue
            }
            if line.hasPrefix("@@ ") {
                finishHunk()
                currentHunk = [line]
                continue
            }
            if currentHunk.isEmpty {
                if !fileHeader.isEmpty {
                    fileHeader.append(line)
                }
            } else {
                currentHunk.append(line)
            }
        }
        finishHunk()
        return result
    }

    private static func displayPath(from header: [String]) -> String {
        for line in header.reversed() where line.hasPrefix("+++ ") {
            var path = String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            if path == "/dev/null" {
                continue
            }
            if path.hasPrefix("b/") || path.hasPrefix("a/") {
                path.removeFirst(2)
            }
            return path
        }
        return ""
    }
}
