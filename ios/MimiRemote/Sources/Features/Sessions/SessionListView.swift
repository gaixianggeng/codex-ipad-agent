import SwiftUI

enum SessionIndexRowStyle {
    case sidebar
    case library
}

enum SessionLibraryStatusFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case needsAttention
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L10n.text("ui.all_status")
        case .active: return L10n.text("ui.running")
        case .needsAttention: return L10n.text("ui.need_to_be_processed")
        case .history: return L10n.text("ui.history")
        }
    }

    func includes(_ session: AgentSession) -> Bool {
        switch self {
        case .all:
            return true
        case .active:
            return session.isRunning
        case .needsAttention:
            return session.status == SessionStatus.waitingForApproval.rawValue ||
                session.status == SessionStatus.waitingForInput.rawValue ||
                session.pendingApproval != nil ||
                session.pendingUserInput != nil ||
                session.status == SessionStatus.failed.rawValue
        case .history:
            return !session.isRunning
        }
    }
}

/// 会话生命周期是列表的第一层信息。保持输入顺序，只负责把仍在进行的任务和历史记录分开。
struct SessionListPartition: Equatable {
    let active: [AgentSession]
    let history: [AgentSession]

    init(sessions: [AgentSession]) {
        active = sessions.filter(\.isRunning)
        history = sessions.filter { !$0.isRunning }
    }
}

/// 完整会话库只展示轻量索引；消息历史仍在用户选中会话后按需加载。
struct SessionListView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedWorkspaceID = "all"
    @State private var selectedStatus: SessionLibraryStatusFilter = .all

    var onNewSession: (() -> Void)?
    var onSelectSession: ((AgentSession) -> Void)?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        List {
            if visibleSessions.isEmpty && !sessionStore.isLoading {
                if sessionStore.isSessionSearchActive && sessionStore.isSearchingRemoteSessionResults {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(L10n.text("ui.searching_historical_conversations"))
                            .font(themeStore.uiFont(size: 13, weight: .medium))
                            .foregroundStyle(tokens.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .accessibilityIdentifier("sessions.search.initialLoading")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ContentUnavailableView {
                        Label(L10n.text("ui.no_matching_session"), systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text(sessionStore.isSessionSearchActive ? L10n.text("ui.try_changing_keywords_or_filter_conditions") : L10n.text("ui.new_sessions_created_from_a_workspace_appear_here"))
                    } actions: {
                        Button(L10n.text("ui.new_session"), action: presentNewSession)
                            .buttonStyle(.borderedProminent)
                            .tint(tokens.primaryAction)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } else {
                if !sessionPartition.active.isEmpty {
                    Section {
                        sessionRows(sessionPartition.active)
                    } header: {
                        sessionSectionHeader(
                            title: L10n.text("ui.in_progress"),
                            systemImage: "bolt.fill",
                            count: sessionPartition.active.count,
                            color: tokens.primaryAction
                        )
                    }
                }

                if !sessionPartition.history.isEmpty {
                    Section {
                        sessionRows(sessionPartition.history)
                    } header: {
                        sessionSectionHeader(
                            title: L10n.text("ui.history"),
                            systemImage: "clock.arrow.circlepath",
                            count: sessionPartition.history.count,
                            color: tokens.tertiaryText
                        )
                    }
                }
            }

            // Gateway 过滤后当前页可能没有可见结果但仍给出 nextCursor，入口必须独立于空态展示。
            if sessionStore.isSessionSearchActive && sessionStore.sessionSearchHasMore {
                Button {
                    Task { await sessionStore.loadMoreSessionSearchResults() }
                } label: {
                    HStack(spacing: 8) {
                        if sessionStore.isLoadingMoreSessionSearchResults {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text(sessionStore.isLoadingMoreSessionSearchResults ? L10n.text("ui.searching_continues") : L10n.text("ui.continue_searching"))
                    }
                    .font(themeStore.uiFont(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.secondaryText)
                .disabled(sessionStore.isLoadingMoreSessionSearchResults)
                .accessibilityIdentifier("sessions.search.loadMore")
                .listRowInsets(.init(top: 4, leading: 20, bottom: 8, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle(L10n.text("ui.session"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $sessionStore.sessionSearchQuery, placement: .navigationBarDrawer(displayMode: .automatic), prompt: L10n.text("ui.search_session"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                filterMenu(tokens: tokens)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                sessionListToolbarButton(
                    systemImage: "arrow.clockwise",
                    accessibilityLabel: L10n.text("ui.refresh_session_library"),
                    tokens: tokens
                ) {
                    Task { await sessionStore.refreshSessionLibraryIndex(authoritative: true) }
                }

                sessionListToolbarButton(
                    systemImage: "plus",
                    accessibilityLabel: L10n.text("ui.new_session_3da224c4"),
                    tokens: tokens,
                    isPrimary: true,
                    action: presentNewSession
                )
                .accessibilityIdentifier("sessions.newSession")
            }
        }
        .task {
            await sessionStore.refreshSessionLibraryIndex()
        }
    }

    /// 使用系统工具栏按钮，让不同系统版本自行处理材质、按下反馈和命中区域。
    private func sessionListToolbarButton(
        systemImage: String,
        accessibilityLabel: String,
        tokens: ThemeTokens,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 15, weight: .semibold))
        }
        .foregroundStyle(isPrimary ? tokens.primaryAction : tokens.secondaryText)
        .tint(isPrimary ? tokens.primaryAction : tokens.accent)
        .accessibilityLabel(accessibilityLabel)
    }

    private var visibleSessions: [AgentSession] {
        sessionStore.sessionLibrarySessions.filter { session in
            (selectedWorkspaceID == "all" || session.projectID == selectedWorkspaceID) &&
                selectedStatus.includes(session)
        }
    }

    private var sessionPartition: SessionListPartition {
        SessionListPartition(sessions: visibleSessions)
    }

    @ViewBuilder
    private func sessionRows(_ sessions: [AgentSession]) -> some View {
        ForEach(sessions) { session in
            SessionIndexRow(
                session: session,
                foregroundActivity: sessionStore.foregroundActivity(for: session.id),
                isSelected: session.id == sessionStore.selectedSessionID,
                isPinned: sessionStore.isSessionPinned(session.id),
                isArchived: sessionStore.isSessionArchived(session.id),
                reminder: sessionStore.sessionReminder(for: session.id),
                isObserving: sessionStore.isSessionObserving(session),
                style: .library,
                searchSnippet: sessionStore.sessionSearchSnippet(for: session.id)
            )
            .contentShape(Rectangle())
            .onTapGesture { select(session) }
            .sessionRowActions(session)
            .listRowInsets(.init(top: 4, leading: 20, bottom: 4, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    private func sessionSectionHeader(
        title: String,
        systemImage: String,
        count: Int,
        color: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(color.opacity(0.72))
        }
        .font(themeStore.uiFont(.caption, weight: .semibold))
        .foregroundStyle(color)
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }

    private func filterMenu(tokens: ThemeTokens) -> some View {
        Menu {
            Section(L10n.text("ui.workspace")) {
                Button {
                    selectedWorkspaceID = "all"
                } label: {
                    Label(L10n.text("ui.all_workspaces"), systemImage: selectedWorkspaceID == "all" ? "checkmark" : "folder")
                }
                ForEach(sessionStore.sidebarProjects) { project in
                    Button {
                        selectedWorkspaceID = project.id
                    } label: {
                        Label(project.name, systemImage: selectedWorkspaceID == project.id ? "checkmark" : "folder")
                    }
                }
            }
            Section(L10n.text("ui.status")) {
                ForEach(SessionLibraryStatusFilter.allCases) { filter in
                    Button {
                        selectedStatus = filter
                    } label: {
                        Label(filter.title, systemImage: selectedStatus == filter ? "checkmark" : "line.3.horizontal.decrease.circle")
                    }
                }
            }
        } label: {
            Label(filterTitle, systemImage: "line.3.horizontal.decrease")
                .foregroundStyle(tokens.secondaryText)
        }
        .accessibilityLabel(L10n.text("ui.filter_sessions"))
    }

    private var filterTitle: String {
        if selectedWorkspaceID != "all",
           let project = sessionStore.sidebarProjects.first(where: { $0.id == selectedWorkspaceID }) {
            return project.name
        }
        return selectedStatus == .all ? L10n.text("ui.filter") : selectedStatus.title
    }

    private func presentNewSession() {
        if let onNewSession {
            onNewSession()
        } else {
            Task { await sessionStore.startNewSession() }
        }
    }

    private func select(_ session: AgentSession) {
        if let onSelectSession {
            onSelectSession(session)
        } else {
            Task { await sessionStore.selectSession(session) }
        }
    }
}

struct SessionIndexRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let session: AgentSession
    let foregroundActivity: SessionForegroundActivity?
    let isSelected: Bool
    let isPinned: Bool
    let isArchived: Bool
    let reminder: SessionReminder?
    let isObserving: Bool
    let style: SessionIndexRowStyle
    var searchSnippet: String? = nil

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: style == .sidebar ? 3 : 7) {
            HStack(alignment: .center, spacing: 7) {
                if style == .library {
                    Circle()
                        .fill(statusColor(tokens: tokens))
                        .frame(width: 7, height: 7)
                }

                Text(session.title)
                    .font(themeStore.uiFont(size: style == .sidebar ? 14 : 16, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(style == .sidebar ? 1 : 2)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                if style == .library {
                    Text(timestampText)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.tertiaryText)
                        .fixedSize()
                }
            }

            HStack(spacing: 6) {
                if isPinned { Image(systemName: "pin.fill") }
                if isArchived { Image(systemName: "archivebox.fill") }
                if reminder != nil { Image(systemName: "bell.fill").foregroundStyle(tokens.warning) }

                Text(session.project.isEmpty ? session.dir : session.project)
                    .lineLimit(1)
                    .truncationMode(.middle)

                statusLabel(tokens: tokens)

                if isObserving {
                    Image(systemName: "eye")
                        .foregroundStyle(tokens.tertiaryText)
                        .accessibilityLabel(L10n.text("ui.just_observe"))
                }

                if style == .sidebar {
                    Text("·")
                    Text(timestampText)
                }
            }
            .font(themeStore.uiFont(size: style == .sidebar ? 10 : 12, weight: .regular))
            .foregroundStyle(tokens.tertiaryText)
            .lineLimit(1)

            if style == .library,
               let searchSnippet,
               !searchSnippet.isEmpty {
                Text(searchSnippet)
                    .font(themeStore.uiFont(size: 12, weight: .regular))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, style == .sidebar ? 10 : 14)
        .padding(.vertical, style == .sidebar ? 6 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(tokens: tokens), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(tokens.primaryAction)
                    .frame(width: 3)
                    .padding(.vertical, 9)
                    .padding(.leading, 2)
            }
        }
        .overlay {
            if style == .library {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(rowBorder(tokens: tokens), lineWidth: 1)
            }
        }
    }

    private var status: AgentSessionDisplayStatus {
        return session.displayStatus(foregroundActivity: foregroundActivity)
    }

    @ViewBuilder
    private func statusLabel(tokens: ThemeTokens) -> some View {
        HStack(spacing: 4) {
            if status.showsSpinner {
                ProgressView()
                    .controlSize(.mini)
                    .tint(statusColor(tokens: tokens))
            } else {
                Image(systemName: status.systemImage)
                    .font(themeStore.uiFont(size: style == .sidebar ? 8 : 10, weight: .semibold))
            }
            Text(status.title)
        }
        .font(themeStore.uiFont(size: style == .sidebar ? 9 : 11, weight: .semibold))
        .foregroundStyle(statusColor(tokens: tokens))
        .padding(.horizontal, style == .sidebar ? 0 : 7)
        .padding(.vertical, style == .sidebar ? 0 : 3)
        .background {
            if style == .library {
                Capsule()
                    .fill(statusColor(tokens: tokens).opacity(status.tone == .neutral ? 0.07 : 0.10))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.title)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func rowBackground(tokens: ThemeTokens) -> Color {
        if isSelected {
            return tokens.selectionFill
        }
        guard style == .library else {
            return .clear
        }
        if session.isRunning {
            return statusColor(tokens: tokens).opacity(0.06)
        }
        return tokens.surface.opacity(0.58)
    }

    private func rowBorder(tokens: ThemeTokens) -> Color {
        if isSelected {
            return tokens.primaryAction.opacity(0.34)
        }
        if session.isRunning {
            return statusColor(tokens: tokens).opacity(0.24)
        }
        return tokens.border.opacity(0.58)
    }

    private func statusColor(tokens: ThemeTokens) -> Color {
        switch status.tone {
        case .active: return tokens.primaryAction
        case .warning: return tokens.warning
        case .danger: return .red
        case .complete, .neutral: return tokens.tertiaryText
        }
    }

    private var timestampText: String {
        guard let date = session.recencyAt ?? session.updatedAt ?? session.createdAt else { return "" }
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        return Self.dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("Hm")
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter
    }()
}

private struct SessionRowActions: ViewModifier {
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var renameTarget: SessionRenameTarget?
    @State private var reviewPresentation: SessionReviewPresentation?
    let session: AgentSession

    func body(content: Content) -> some View {
        let isPinned = sessionStore.isSessionPinned(session.id)
        let isArchived = sessionStore.isSessionArchived(session.id)
        let reminder = sessionStore.sessionReminder(for: session.id)

        content.contextMenu {
            if sessionStore.isSessionObserving(session) {
                Button {
                    sessionStore.takeOverSession(session)
                } label: {
                    Label(L10n.text("ui.take_over_to_ipad"), systemImage: "hand.raised.fill")
                }
            }

            Button {
                sessionStore.toggleSessionPinned(session)
            } label: {
                Label(isPinned ? L10n.text("ui.unpin") : L10n.text("ui.pin_to_top"), systemImage: isPinned ? "pin.slash" : "pin")
            }

            if sessionStore.supportsCodexThreadManagement(session) {
                Divider()

                Button {
                    renameTarget = SessionRenameTarget(session: session)
                } label: {
                    Label(L10n.text("ui.rename"), systemImage: "pencil")
                }

                Button {
                    Task { await sessionStore.compactSessionContext(session) }
                } label: {
                    Label(L10n.text("ui.compression_context"), systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .disabled(session.isRunning)

                Button {
                    reviewPresentation = SessionReviewPresentation(session: session)
                } label: {
                    Label(L10n.text("ui.start_code_review"), systemImage: "checklist.checked")
                }
                .disabled(session.isRunning)
            }

            Button {
                Task { await sessionStore.handoffSessionToWorktree(session) }
            } label: {
                Label(L10n.text("ui.go_to_the_new_git_worktree"), systemImage: "arrow.triangle.branch")
            }
            .disabled(session.isRunning || sessionStore.isCreatingWorktree)

            Menu {
                Button(L10n.text("ui.30_minutes_later")) { Task { await sessionStore.scheduleSessionReminder(session, after: 30 * 60) } }
                Button(L10n.text("ui.2_hours_later")) { Task { await sessionStore.scheduleSessionReminder(session, after: 2 * 60 * 60) } }
                Button(L10n.text("ui.tomorrow")) { Task { await sessionStore.scheduleSessionReminder(session, after: 24 * 60 * 60) } }
                if reminder != nil {
                    Button(L10n.text("ui.clear_reminder"), role: .destructive) { sessionStore.clearSessionReminder(session) }
                }
            } label: {
                Label(L10n.text("ui.reminder"), systemImage: reminder == nil ? "bell" : "bell.fill")
            }

            Button(role: isArchived ? nil : .destructive) {
                Task { await sessionStore.toggleSessionArchivedRemote(session) }
            } label: {
                Label(isArchived ? L10n.text("ui.unarchive") : L10n.text("ui.archive"), systemImage: isArchived ? "archivebox.fill" : "archivebox")
            }
        }
        .sheet(item: $renameTarget) { target in
            SessionRenameSheet(session: target.session)
        }
        .sheet(item: $reviewPresentation) { presentation in
            SessionReviewSheet(session: presentation.session)
        }
    }
}

private struct SessionRenameTarget: Identifiable {
    let session: AgentSession
    var id: SessionID { session.id }
}

private struct SessionReviewPresentation: Identifiable {
    let session: AgentSession
    var id: SessionID { session.id }
}

private enum SessionReviewScope: String, CaseIterable, Identifiable {
    case uncommittedChanges
    case baseBranch
    case commit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uncommittedChanges: return L10n.text("ui.changes_not_committed")
        case .baseBranch: return L10n.text("ui.relative_base_branch")
        case .commit: return L10n.text("ui.specify_submission")
        }
    }

    var systemImage: String {
        switch self {
        case .uncommittedChanges: return "pencil.and.list.clipboard"
        case .baseBranch: return "arrow.triangle.branch"
        case .commit: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

private struct SessionReviewSheet: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let session: AgentSession
    @State private var scope: SessionReviewScope = .uncommittedChanges
    @State private var baseBranch = ""
    @State private var commitSHA = ""
    @State private var isSubmitting = false
    @State private var submissionError: String?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            Form {
                Section(L10n.text("ui.review_goals")) {
                    Picker(L10n.text("ui.target_type"), selection: $scope) {
                        ForEach(SessionReviewScope.allCases) { option in
                            Label(option.title, systemImage: option.systemImage)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                }

                switch scope {
                case .uncommittedChanges:
                    Section {
                        Label(L10n.text("ui.review_all_uncommitted_changes_in_the_current_workspace"), systemImage: "info.circle")
                            .foregroundStyle(tokens.secondaryText)
                    }
                case .baseBranch:
                    Section {
                        TextField(L10n.text("ui.for_example_main"), text: $baseBranch)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit(submit)
                            .accessibilityIdentifier("sessions.review.baseBranch")
                    } header: {
                        Text(L10n.text("ui.base_branch"))
                    } footer: {
                        Text(normalizedBaseBranch.isEmpty ? L10n.text("ui.please_enter_a_non_empty_branch_name") : L10n.format("ui.the_current_branch_will_be_reviewed_for_differences", normalizedBaseBranch))
                            .foregroundStyle(normalizedBaseBranch.isEmpty ? tokens.warning : tokens.tertiaryText)
                    }
                case .commit:
                    Section {
                        TextField(L10n.text("ui.commit_sha"), text: $commitSHA)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit(submit)
                            .accessibilityIdentifier("sessions.review.commit")
                    } header: {
                        Text(L10n.text("ui.submit"))
                    } footer: {
                        Text(normalizedCommitSHA.isEmpty ? L10n.text("ui.please_enter_a_non_empty_commit_sha") : L10n.format("ui.only_submission_value_will_be_reviewed", normalizedCommitSHA))
                            .foregroundStyle(normalizedCommitSHA.isEmpty ? tokens.warning : tokens.tertiaryText)
                    }
                }

                Section {
                    Label(L10n.text("ui.review_is_always_executed_within_the_current_session"), systemImage: "lock.shield")
                        .foregroundStyle(tokens.tertiaryText)
                }

                if let submissionError {
                    Section {
                        Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(tokens.warning)
                    }
                }
            }
            .font(themeStore.uiFont(.body))
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            .navigationTitle(L10n.text("ui.start_code_review"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(L10n.text("ui.start"))
                        }
                    }
                    .disabled(isSubmitting || session.isRunning || normalizedTarget == nil)
                    .accessibilityIdentifier("sessions.review.submit")
                }
            }
        }
        .tint(tokens.primaryAction)
        .interactiveDismissDisabled(isSubmitting)
        .presentationDetents([.medium, .large])
    }

    private var normalizedBaseBranch: String {
        baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedCommitSHA: String {
        commitSHA.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedTarget: CodexAppServerReviewTarget? {
        switch scope {
        case .uncommittedChanges:
            return .uncommittedChanges
        case .baseBranch:
            guard !normalizedBaseBranch.isEmpty else { return nil }
            return .baseBranch(normalizedBaseBranch)
        case .commit:
            guard !normalizedCommitSHA.isEmpty else { return nil }
            return .commit(sha: normalizedCommitSHA)
        }
    }

    private func submit() {
        guard !isSubmitting, !session.isRunning, let target = normalizedTarget else { return }
        isSubmitting = true
        submissionError = nil
        Task {
            let didStart = await sessionStore.startReview(session, target: target)
            isSubmitting = false
            if didStart {
                dismiss()
            } else {
                submissionError = sessionStore.statusMessage ?? L10n.text("ui.review_failed_to_start_please_try_again_later")
            }
        }
    }
}

private struct SessionRenameSheet: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(\.dismiss) private var dismiss

    let session: AgentSession
    @State private var name: String
    @State private var isSaving = false

    init(session: AgentSession) {
        self.session = session
        _name = State(initialValue: session.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("ui.session_name")) {
                    TextField(L10n.text("ui.enter_name"), text: $name)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .onSubmit(save)
                }
            }
            .navigationTitle(L10n.text("ui.rename_session"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? L10n.text("ui.saving_6644f061") : L10n.text("ui.save"), action: save)
                        .disabled(isSaving || normalizedName.isEmpty || normalizedName == session.title)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !isSaving, !normalizedName.isEmpty else { return }
        isSaving = true
        Task {
            let didRename = await sessionStore.renameSession(session, name: normalizedName)
            isSaving = false
            if didRename {
                dismiss()
            }
        }
    }
}

extension View {
    func sessionRowActions(_ session: AgentSession) -> some View {
        modifier(SessionRowActions(session: session))
    }
}
