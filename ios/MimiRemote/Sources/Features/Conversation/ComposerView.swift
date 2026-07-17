import AVFoundation
import AudioToolbox
import ImageIO
import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum VoiceTranscriptionDefaults {
    // iPad 端以中文口述为主，固定语言能降低短句和中英混合技术词的误判率。
    static let languageCode = "zh"
}

struct ComposerView: View {
    // 相关实现按职责分布在 Composer* 扩展文件中；这些成员保持 module-internal，
    // 仅用于跨文件扩展协作，不构成对外 API。
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var themeStore: ThemeStore
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @State var composerState = ComposerState()
    @State var activeComposerDraftScope = ComposerDraftScopeKey.none
    @State var composerTextExternalRevision = 0
    @StateObject var voiceInput = VoiceInputController()
    @State var photoLibraryPickerRequest: PhotoLibraryPickerRequest?
    @State var showsAddContentPanel = false
    @State var showsSkillPicker = false
    @State var showsModelGridPicker = false
    @State var showsManualSkillInputSheet = false
    @State var showsAdvancedOptionsSheet = false
    @State var previewingAttachment: CodexAppServerUserInput?
    @State var goalEditor: ThreadGoalEditorDraft?
    @State var isGoalStatusExpanded = false
    @State var hiddenCompletedGoalIDs: Set<SessionID> = []
    @State var attachmentErrorMessage: String?
    @State var isVoicePressActive = false
    @State var isVoiceTranscribing = false
    @State var voiceTranscriptionTask: Task<Void, Never>?
    @State var activeVoiceTranscriptionContext: VoiceTranscriptionContext?
    @State var retryableVoiceTranscription: RetryableVoiceTranscription?
    @State var measuredComposerTextHeight: CGFloat = 0
    @State var isComposerTextComposing = false
    @State var composerTextSubmitBridge = ComposerTextSubmitBridge()
    @State var activeSkillQuery: ComposerSkillQuery?
    @State var selectedSkillSuggestionIndex = 0
    @AppStorage("agentd.developerMode") var developerModeEnabled = false
    @AppStorage(ComposerPermissionMode.defaultStorageKey) var defaultPermissionModeID = ComposerPermissionMode.defaultMode.rawValue
    // 快捷行默认收起：展开与否是用户的全局偏好，不再被宽度变化反向改写。
    @AppStorage("composer.shortcuts.expanded") var prefersExpandedShortcutBar = false
    @State var guidedFollowUpEnabled = false
    @State var editingQueuedTurn: QueuedTurnEditorDraft?
    @State var showsQueuedTurnManager = false

    var availableWidth: CGFloat?

    init(availableWidth: CGFloat? = nil, initialGoalStatusExpanded: Bool = false) {
        self.availableWidth = availableWidth
        _isGoalStatusExpanded = State(initialValue: initialGoalStatusExpanded)
    }

    static let minimumUsableVoiceDuration: TimeInterval = 0.35
    static let completedGoalAutoHideDelayNanoseconds: UInt64 = 3_500_000_000
    static let maximumImageAttachmentCount = 8

    var composerMotionAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.34, dampingFraction: 1, blendDuration: 0.08)
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        // 外层保持透明，由输入卡片承担唯一主表面；这样和首页“暖色底 + 白色浮层”的
        // 层级一致，也避免状态提示、输入框和底部 dock 形成三层嵌套。
        VStack(alignment: .leading, spacing: 10) {
            queuedTurnTray
            composerStatusTray
            pendingApprovalAction
            pendingUserInputAction
            voiceErrorMessage
            voiceNoticeMessage
            attachmentErrorNotice
            attachmentStrip
            composerStatusRow
            composerInputRow(tokens: tokens)
            voiceKeyboardShortcutButton
                .overlay {
                    composerKeyboardShortcutButtons
                }
        }
        .sheet(isPresented: $showsManualSkillInputSheet) {
            ManualSkillInputSheet { input in
                composerState.addAttachment(input)
            }
        }
        .sheet(isPresented: $showsAdvancedOptionsSheet) {
            AdvancedTurnOptionsSheet(options: composerState.turnOptions) { options in
                composerState.updateTurnOptions { $0 = options }
            }
        }
        .sheet(item: $previewingAttachment) { item in
            AttachmentPreviewSheet(item: item)
                .environmentObject(themeStore)
        }
        .sheet(item: $goalEditor) { draft in
            ThreadGoalEditorSheet(draft: draft)
                .environmentObject(sessionStore)
                .environmentObject(themeStore)
        }
        .sheet(item: $editingQueuedTurn) { draft in
            QueuedTurnEditorSheet(draft: draft) { payload in
                _ = sessionStore.updateQueuedTurn(
                    clientMessageID: draft.id,
                    payload: payload
                )
            }
            .environmentObject(themeStore)
        }
        .sheet(isPresented: $showsQueuedTurnManager) {
            QueuedTurnManagerSheet(
                turns: sessionStore.selectedQueuedTurns,
                canGuideCurrentTurn: canUseGuidedFollowUp,
                onUpdate: { turn, payload in
                    _ = sessionStore.updateQueuedTurn(clientMessageID: turn.id, payload: payload)
                },
                onDelete: { _ = sessionStore.deleteQueuedTurn(clientMessageID: $0.id) },
                onRetry: { _ = sessionStore.retryQueuedTurn(clientMessageID: $0.id) },
                onGuideNow: { _ = sessionStore.guideQueuedTurnNow(clientMessageID: $0.id) },
                onMove: { source, destination in
                    _ = sessionStore.moveSelectedQueuedTurns(fromOffsets: source, toOffset: destination)
                }
            )
            .environmentObject(themeStore)
        }
        .sheet(item: $photoLibraryPickerRequest) { request in
            PhotoLibraryPicker(selectionLimit: request.selectionLimit) { results in
                photoLibraryPickerRequest = nil
                guard !results.isEmpty else {
                    return
                }
                loadPhotoAttachments(results, targetScope: request.targetScope)
            }
            .ignoresSafeArea()
        }
        .onChange(of: developerModeEnabled) { _, enabled in
            guard !enabled else {
                return
            }
            composerState.updateTurnOptions { options in
                options = options.sanitizedForStandardComposer()
            }
            showsAdvancedOptionsSheet = false
        }
        .onChange(of: defaultPermissionModeID) { _, _ in
            applyDefaultPermissionMode()
        }
        .onChange(of: currentComposerDraftScope) { _, newScope in
            switchComposerDraftScope(to: newScope)
        }
        .onChange(of: composerState.draftSnapshot()) { _, snapshot in
            // 每次确认文字或附件变化都写入稳定内存仓，视图突然重建时也能恢复最新草稿。
            sessionStore.saveComposerDraft(snapshot, for: activeComposerDraftScope)
        }
        .onChange(of: selectedSessionRuntimeProviderForModelMenu) { _, _ in
            clampModelSelectionToSelectedSessionRuntime()
            clampPermissionSelectionToSelectedSessionRuntime()
        }
        .onChange(of: canUseGuidedFollowUp) { _, canGuide in
            if !canGuide {
                guidedFollowUpEnabled = false
            }
        }
        .onChange(of: sessionStore.selectedSessionID) { _, _ in
            // 引导是只对当前正在生成的回复生效的一次性选择。切换会话后恢复安全的
            // 默认排队，避免把上一条会话的发送意图意外带到另一条运行中会话。
            guidedFollowUpEnabled = false
        }
        .onChange(of: sessionStore.selectedThreadGoal) { previousGoal, goal in
            syncGoalStatusBarVisibility(from: previousGoal, to: goal)
        }
        .task(id: voiceInput.errorMessage) {
            await autoDismissVoiceErrorIfNeeded(voiceInput.errorMessage)
        }
        .onAppear {
            switchComposerDraftScope(to: currentComposerDraftScope)
            clampModelSelectionToSelectedSessionRuntime()
            clampPermissionSelectionToSelectedSessionRuntime()
        }
        .task {
            switchComposerDraftScope(to: currentComposerDraftScope)
            clampModelSelectionToSelectedSessionRuntime()
            applyDefaultPermissionMode()
            voiceInput.prewarm()
            await sessionStore.refreshAppServerModelOptions()
            await sessionStore.refreshCapabilities()
        }
        .onDisappear {
            synchronizeComposerTextBeforeDraftScopeChange()
            sessionStore.saveComposerDraft(composerState.draftSnapshot(), for: activeComposerDraftScope)
            cancelVoiceInteraction(clearStatus: true)
            activeSkillQuery = nil
        }
    }

    @discardableResult
    func submitDraft() -> Bool {
        guard synchronizeComposerTextBeforeSubmit() else {
            return false
        }
        if composerState.isGoalModeSelected {
            return submitGoalDraft()
        }
        let submittedDraftScope = activeComposerDraftScope
        let options = preparedTurnOptionsForSubmit()
        guard let submitted = composerState.takeDraftForSubmit(isLoading: sessionStore.isLoading, turnOptionsOverride: options) else {
            return false
        }
        sessionStore.removeComposerDraft(for: submittedDraftScope)
        let runningDelivery = runningTurnDeliveryForSubmit
        cancelVoiceInteraction(clearStatus: false)
        clearVoiceTransientStatus()
        Task {
            let accepted = await sessionStore.sendTurn(submitted.payload, runningDelivery: runningDelivery)
            if !accepted {
                await MainActor.run {
                    restoreSubmittedDraft(submitted, originalScope: submittedDraftScope)
                }
            } else {
                await MainActor.run {
                    sessionStore.removeComposerDraft(for: submittedDraftScope)
                    guidedFollowUpEnabled = false
                    resetComposerSendModeAfterSubmit()
                }
            }
        }
        return true
    }

    @discardableResult
    func submitGoalDraft() -> Bool {
        var options = preparedTurnOptionsForSubmit()
        // 目标模式不是 Plan Mode：目标元数据走 thread/goal/set，turn/start 仍显式声明 default，
        // 防止 app-server 沿用上一轮规划协作状态。
        options.collaborationMode = .default
        options.planGuidanceEnabled = false
        let submittedDraftScope = activeComposerDraftScope
        guard let submitted = composerState.takeDraftForSubmit(
            isLoading: sessionStore.isLoading || sessionStore.isUpdatingThreadGoal,
            turnOptionsOverride: options
        ) else {
            return false
        }
        sessionStore.removeComposerDraft(for: submittedDraftScope)
        let objective = submitted.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else {
            composerState.restore(submitted)
            sessionStore.saveComposerDraft(composerState.draftSnapshot(), for: submittedDraftScope)
            return false
        }
        let runningDelivery = runningTurnDeliveryForSubmit
        cancelVoiceInteraction(clearStatus: false)
        clearVoiceTransientStatus()
        Task {
            let accepted = await sessionStore.startGoalTurn(
                payload: submitted.payload,
                objective: objective,
                runningDelivery: runningDelivery
            )
            if !accepted {
                await MainActor.run {
                    restoreSubmittedDraft(submitted, originalScope: submittedDraftScope)
                }
            } else {
                await MainActor.run {
                    sessionStore.removeComposerDraft(for: submittedDraftScope)
                    guidedFollowUpEnabled = false
                    resetComposerSendModeAfterSubmit()
                }
            }
        }
        return true
    }

    func synchronizeComposerTextBeforeSubmit() -> Bool {
        guard let snapshot = composerTextSubmitBridge.snapshotForSubmit() else {
            return true
        }
        guard !snapshot.isComposing else {
            // 中文输入法合成中的文本还不是用户最终选择，提交时直接拒绝，避免发送旧 draft。
            if !isComposerTextComposing {
                isComposerTextComposing = true
            }
            return false
        }
        if composerState.draft != snapshot.text {
            // 只在提交前同步一次 UIKit 最终文本，避免 marked text 每次变化都触发全局状态重绘。
            composerState.draft = snapshot.text
        }
        if isComposerTextComposing {
            isComposerTextComposing = false
        }
        return true
    }

    var currentComposerDraftScope: ComposerDraftScopeKey {
        ComposerDraftScopeKey.current(
            selectedSessionID: sessionStore.selectedSessionID,
            selectedProjectID: sessionStore.selectedProjectID
        )
    }

    func switchComposerDraftScope(to nextScope: ComposerDraftScopeKey) {
        guard activeComposerDraftScope != nextScope else {
            return
        }
        let previousScope = activeComposerDraftScope
        let isOptimisticHandoff = isOptimisticSessionHandoff(from: previousScope, to: nextScope)
        let restoredSendMode = sessionStore.composerSendModeForScopeActivation(
            previousScope: previousScope,
            nextScope: nextScope,
            currentMode: composerState.sendMode,
            isOptimisticSessionHandoff: isOptimisticHandoff
        )
        synchronizeComposerTextBeforeDraftScopeChange()
        let outgoingDraft = composerState.draftSnapshot()
        sessionStore.saveComposerDraft(outgoingDraft, for: previousScope)
        if isOptimisticHandoff {
            // local:* 只是创建接口返回前的临时身份。服务端 ID 回来时迁移当前可见草稿，
            // 避免用户正在输入的追加指令被新 scope 的空草稿覆盖。
            sessionStore.saveComposerDraft(outgoingDraft, for: nextScope)
            sessionStore.removeComposerDraft(for: previousScope)
        }
        cancelVoiceInteraction(clearStatus: true)

        applyDefaultPermissionMode()
        // 先切 scope 再恢复，避免 restore 触发的 onChange 把新会话草稿误写回旧 scope。
        activeComposerDraftScope = nextScope
        composerState.setSendMode(restoredSendMode)
        persistComposerSendMode(restoredSendMode, for: nextScope)
        composerState.restoreDraftSnapshot(sessionStore.composerDraft(for: nextScope))
        composerTextExternalRevision += 1
        guidedFollowUpEnabled = false
        measuredComposerTextHeight = 0
        isComposerTextComposing = false
    }

    func isOptimisticSessionHandoff(
        from previousScope: ComposerDraftScopeKey,
        to nextScope: ComposerDraftScopeKey
    ) -> Bool {
        guard case .session(let previousSessionID) = previousScope,
              case .session(let nextSessionID) = nextScope
        else {
            return false
        }
        return previousSessionID.hasPrefix("local:") && !nextSessionID.hasPrefix("local:")
    }

    func persistComposerSendMode(_ mode: ComposerSendMode, for scope: ComposerDraftScopeKey) {
        sessionStore.saveComposerSendMode(mode, for: scope)
    }

    func resetComposerSendModeAfterSubmit() {
        composerState.resetSendModeAfterSubmit()
        persistComposerSendMode(.standard, for: activeComposerDraftScope)
    }

    func synchronizeComposerTextBeforeDraftScopeChange() {
        guard let snapshot = composerTextSubmitBridge.snapshotForSubmit() else {
            return
        }
        if snapshot.isComposing {
            // resize/切会话时即使仍在输入法候选态，也保留当前可见文本；恢复拼音比静默丢失整个草稿更安全。
            isComposerTextComposing = true
        }
        if composerState.draft != snapshot.text {
            composerState.draft = snapshot.text
        }
        if isComposerTextComposing && !snapshot.isComposing {
            isComposerTextComposing = false
        }
    }

    @MainActor
    func restoreSubmittedDraft(_ submitted: SubmittedComposerDraft, originalScope: ComposerDraftScopeKey) {
        let restoreScope = submittedDraftRestoreScope(originalScope: originalScope)
        if restoreScope == activeComposerDraftScope {
            composerState.restore(submitted)
        } else {
            sessionStore.saveComposerDraft(ComposerDraftSnapshot(submitted: submitted), for: restoreScope)
        }
    }

    func submittedDraftRestoreScope(originalScope: ComposerDraftScopeKey) -> ComposerDraftScopeKey {
        // 新建会话提交时会先进入 local:<project>:<client_message_id> 乐观会话；
        // 如果创建失败，草稿应回到这个用户正在看的失败会话，而不是藏回项目入口。
        if case .session(let sessionID) = activeComposerDraftScope,
           sessionID.hasPrefix("local:") || sessionStore.selectedSession?.source == "local" {
            return activeComposerDraftScope
        }
        return originalScope
    }

    func preparedTurnOptionsForSubmit() -> CodexAppServerTurnOptions {
        var options = developerModeEnabled ? composerState.turnOptions : composerState.turnOptions.sanitizedForStandardComposer()
        if composerState.isPlanModeSelected {
            options.collaborationMode = .plan
            options.planGuidanceEnabled = true
        } else {
            // 普通发送也必须显式退出 Plan Mode，不能依赖 nil/absent。
            options.collaborationMode = .default
            options.planGuidanceEnabled = false
        }
        return options
    }

    var canChooseRunningFollowUpDelivery: Bool {
        guard let session = sessionStore.selectedSession else {
            return false
        }
        return session.isRunning &&
            composerState.sendMode == .standard &&
            sessionStore.canControlSession(session)
    }

    var canUseGuidedFollowUp: Bool {
        guard let session = sessionStore.selectedSession else {
            return false
        }
        return canChooseRunningFollowUpDelivery && session.activeTurnID != nil
    }

    var runningTurnDeliveryForSubmit: RunningTurnDelivery {
        composerState.runningTurnDelivery(
            canUseGuidedFollowUp: canUseGuidedFollowUp,
            guidedFollowUpEnabled: guidedFollowUpEnabled
        )
    }

    var canSubmitDraft: Bool {
        guard !isComposerTextComposing else {
            return false
        }
        if composerState.isGoalModeSelected {
            return canSubmitGoalDraft
        }
        return sessionStore.canSendInSelectedSession && composerState.canSubmit(isLoading: sessionStore.isLoading)
    }

    var canSubmitGoalDraft: Bool {
        sessionStore.canSendInSelectedSession && composerState.hasNonWhitespaceDraft && !sessionStore.isLoading && !sessionStore.isUpdatingThreadGoal
    }

    var usesCompactComposerMetrics: Bool {
        ConversationLayout.usesCompactComposerMetrics(
            availableWidth: availableWidth,
            horizontalSizeClass: horizontalSizeClass
        )
    }


    @ViewBuilder
    var queuedTurnTray: some View {
        let turns = sessionStore.selectedQueuedTurns
        if !turns.isEmpty || sessionStore.queuedTurnStorageErrorMessage != nil {
            let tokens = themeStore.tokens(for: colorScheme)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full")
                        .foregroundStyle(tokens.accent)
                    Text("待发送 \(turns.count) 条")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text("保存在此设备")
                        .font(themeStore.uiFont(.caption2, weight: .medium))
                        .foregroundStyle(tokens.tertiaryText)
                    Spacer(minLength: 4)
                    if turns.count > 1 {
                        Button("管理") {
                            showsQueuedTurnManager = true
                        }
                        .buttonStyle(.borderless)
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                    }
                }

                ForEach(Array(turns.prefix(queuedTurnPreviewLimit))) { turn in
                    queuedTurnRow(turn, tokens: tokens)
                }

                if let message = sessionStore.queuedTurnStorageErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(themeStore.uiFont(.caption2, weight: .medium))
                        .foregroundStyle(tokens.warning)
                        .lineLimit(2)
                }
            }
            .padding(10)
            .background(tokens.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tokens.accent.opacity(0.22))
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }

    var queuedTurnPreviewLimit: Int {
        usesCompactComposerMetrics ? 2 : 3
    }

    func queuedTurnRow(_ turn: QueuedTurnEntry, tokens: ThemeTokens) -> some View {
        HStack(spacing: 9) {
            Image(systemName: turn.displayIcon)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(turn.displayTint(tokens: tokens))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(turn.previewText.isEmpty ? "（仅附件）" : turn.previewText)
                    .font(themeStore.uiFont(.caption, weight: .medium))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                Text(turn.displayStatusText)
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(turn.displayTint(tokens: tokens))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    editingQueuedTurn = QueuedTurnEditorDraft(turn: turn)
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .disabled(turn.dispatchState == .dispatching)

                if turn.intent.canGuideCurrentTurn {
                    Button {
                        _ = sessionStore.guideQueuedTurnNow(clientMessageID: turn.id)
                    } label: {
                        Label("立即引导当前回复", systemImage: "text.bubble")
                    }
                    .disabled(!canUseGuidedFollowUp || turn.dispatchState != .waiting)
                }

                if turn.dispatchState == .needsConfirmation {
                    Button {
                        _ = sessionStore.retryQueuedTurn(clientMessageID: turn.id)
                    } label: {
                        Label("确认并重试", systemImage: "arrow.clockwise")
                    }
                }

                Divider()
                Button(role: .destructive) {
                    _ = sessionStore.deleteQueuedTurn(clientMessageID: turn.id)
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(turn.dispatchState == .dispatching)
            } label: {
                Image(systemName: "ellipsis")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.secondaryText)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("待发送消息操作")
        }
        .padding(.leading, 2)
    }


    @ViewBuilder
    var composerStatusTray: some View {
        let visibleGoal = selectedVisibleThreadGoal
        let usageNotice = selectedComposerUsageNotice
        if sessionStore.selectedSessionControlNotice != nil ||
            usageNotice != nil ||
            visibleGoal != nil {
            ComposerStatusTray(
                sessionControlNotice: sessionStore.selectedSessionControlNotice,
                // 阻断额度已经由 Conversation 顶部唯一状态区展示，Composer 不再重复一份。
                quotaNotice: nil,
                usage: usageNotice,
                goal: visibleGoal,
                isGoalExpanded: isGoalStatusExpanded,
                isGoalUpdating: sessionStore.isUpdatingThreadGoal,
                goalErrorMessage: sessionStore.threadGoalErrorMessage,
                isRefreshDisabled: sessionStore.isRefreshingSelectedSession || sessionStore.isLoading,
                onTakeOver: {
                    sessionStore.takeOverSelectedSession()
                },
                onRefreshUsage: {
                    Task {
                        await sessionStore.refreshCurrentContext()
                    }
                },
                onEditGoal: {
                    if let goal = visibleGoal {
                        goalEditor = ThreadGoalEditorDraft(sessionID: goal.threadID, existing: goal)
                    }
                },
                onTogglePauseGoal: {
                    if let goal = visibleGoal {
                        Task { await sessionStore.updateSelectedThreadGoalStatus(nextPrimaryGoalStatus(for: goal.status)) }
                    }
                },
                onCompleteGoal: {
                    Task { await sessionStore.updateSelectedThreadGoalStatus(.complete) }
                },
                onClearGoal: {
                    Task { await sessionStore.clearSelectedThreadGoal() }
                },
                onToggleGoalExpanded: {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isGoalStatusExpanded.toggle()
                    }
                }
            )
            .environmentObject(themeStore)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: visibleGoal.map { completedGoalAutoHideTaskID(for: $0) } ?? "no-goal") {
                if let visibleGoal {
                    await autoHideCompletedGoalIfNeeded(visibleGoal)
                }
            }
        }
    }

    var selectedComposerUsageNotice: CodexUsageDisplaySummary? {
        guard sessionStore.selectedQuotaNotice == nil,
              let usage = sessionStore.selectedCodexUsageDisplay,
              !usage.isExhausted,
              usage.isNearLimit
        else {
            return nil
        }
        return usage
    }

    var selectedVisibleThreadGoal: ThreadGoal? {
        guard let goal = sessionStore.selectedThreadGoal, shouldShowGoalStatusBar(goal) else {
            return nil
        }
        return goal
    }

    // 输入框上方只保留瞬时状态和必要控制。模型、权限、seq/usage 已有其他入口，
    // 常驻展示只会增加工程噪音，因此收进“会话选项”或顶部状态区。
    @ViewBuilder
    var composerStatusRow: some View {
        let showWave = isVoiceActive
        let showControls = canShowRunningControls
        if showWave || showControls {
            HStack(spacing: 10) {
                if showWave {
                    voiceWaveformContent
                        .layoutPriority(1)
                }
                Spacer(minLength: 0)
                if showControls {
                    runningControls
                        .layoutPriority(1)
                }
            }
        }
    }

    var isVoiceActive: Bool {
        voiceInput.isRecording || voiceInput.isPreparing || isVoicePressActive || isVoiceTranscribing
    }

    var canShowRunningControls: Bool {
        sessionStore.selectedSession?.isRunning == true && sessionStore.canControlSession(sessionStore.selectedSession)
    }

    var canInterruptSelectedSession: Bool {
        guard let session = sessionStore.selectedSession else {
            return false
        }
        return session.isRunning &&
            session.activeTurnID != nil &&
            sessionStore.canControlSession(session) &&
            sessionStore.webSocketStatus == .connected
    }

    var runningControls: some View {
        HStack(spacing: 8) {
            if canInterruptSelectedSession {
                Button {
                    sessionStore.sendCtrlC()
                } label: {
                    Label("Ctrl-C", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .accessibilityLabel("发送 Ctrl-C")
            }

            Button {
                Task { await sessionStore.stopSelectedSession() }
            } label: {
                Label("停止", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .tint(themeStore.tokens(for: colorScheme).primaryAction)
            .accessibilityLabel("停止当前会话")
        }
        .controlSize(.small)
        .font(themeStore.uiFont(.caption, weight: .medium))
        .layoutPriority(1)
    }

    func shouldShowGoalStatusBar(_ goal: ThreadGoal) -> Bool {
        goal.status != .complete || !hiddenCompletedGoalIDs.contains(goal.threadID)
    }

    func completedGoalAutoHideTaskID(for goal: ThreadGoal) -> String {
        [
            goal.threadID,
            goal.status.rawValue,
            goal.updatedAt.map { String($0.timeIntervalSince1970) } ?? "no-update"
        ].joined(separator: "#")
    }

    func syncGoalStatusBarVisibility(from previousGoal: ThreadGoal?, to goal: ThreadGoal?) {
        guard let goal else {
            isGoalStatusExpanded = false
            return
        }
        if previousGoal?.threadID != goal.threadID {
            isGoalStatusExpanded = false
        }
        // 目标重新进入非完成态时，恢复 composer 上方的常驻状态条。
        if goal.status != .complete {
            hiddenCompletedGoalIDs.remove(goal.threadID)
        }
    }

    func autoHideCompletedGoalIfNeeded(_ goal: ThreadGoal) async {
        guard goal.status == .complete else {
            return
        }
        try? await Task.sleep(nanoseconds: Self.completedGoalAutoHideDelayNanoseconds)
        guard !Task.isCancelled else {
            return
        }
        await MainActor.run {
            guard sessionStore.selectedThreadGoal?.threadID == goal.threadID,
                  sessionStore.selectedThreadGoal?.status == .complete else {
                return
            }
            withAnimation(.easeInOut(duration: 0.18)) {
                hiddenCompletedGoalIDs.insert(goal.threadID)
                isGoalStatusExpanded = false
            }
        }
    }

    func nextPrimaryGoalStatus(for status: ThreadGoalStatus) -> ThreadGoalStatus {
        switch status {
        case .active:
            return .paused
        case .paused, .blocked, .usageLimited, .budgetLimited, .complete:
            return .active
        }
    }

    func composerInputRow(tokens: ThemeTokens) -> some View {
        composerCard(tokens: tokens)
            .layoutPriority(1)
    }

    func composerCard(tokens: ThemeTokens) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return VStack(alignment: .leading, spacing: composerCardSpacing) {
            composerShortcutRow
            composerTextArea(tokens: tokens)
            skillAutocompletePanel
            voiceReviewNotice
            primaryComposerToolbar
        }
        .padding(composerCardPadding)
        .frame(maxWidth: .infinity)
        .background {
            if reduceTransparency {
                shape.fill(tokens.inputBackground)
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay {
                        shape.fill(tokens.inputBackground.opacity(colorScheme == .light ? 0.72 : 0.58))
                    }
            }
        }
        .tint(tokens.accent)
        .overlay {
            shape.strokeBorder(composerCardBorderColor(tokens), lineWidth: composerCardBorderWidth)
        }
        .shadow(color: composerCardShadow(tokens), radius: 8, y: 3)
    }

    func composerCardShadow(_ tokens: ThemeTokens) -> Color {
        // 浅色只做很轻的悬浮感；深色适当提高阴影不透明度，避免输入卡融进暖黑背景。
        Color.black.opacity(tokens.resolvedScheme == .light ? 0.07 : 0.24)
    }

    func composerTextArea(tokens: ThemeTokens) -> some View {
        ZStack(alignment: .topLeading) {
            ComposerTextView(
                text: composerDraftBinding,
                submitBridge: composerTextSubmitBridge,
                font: composerUIFont,
                textColor: UIColor(tokens.primaryText),
                tintColor: UIColor(tokens.accent),
                externalTextRevision: composerTextExternalRevision,
                minHeight: composerMinHeight,
                maxHeight: composerMaxHeight,
                onSubmit: { submitDraft() },
                onContentHeightChange: { height in
                    if abs(measuredComposerTextHeight - height) > 0.5 {
                        measuredComposerTextHeight = height
                    }
                },
                onCompositionStateChange: { isComposing in
                    if isComposerTextComposing != isComposing {
                        isComposerTextComposing = isComposing
                    }
                },
                onVoiceShortcutPressChanged: { pressed in
                    if pressed {
                        beginHoldToTalk()
                    } else {
                        endHoldToTalk()
                    }
                },
                skillAutocompleteActive: activeSkillQuery != nil && !filteredSkillSuggestions.isEmpty,
                onSkillQueryChange: { query in
                    if query != activeSkillQuery {
                        activeSkillQuery = query
                        selectedSkillSuggestionIndex = 0
                    }
                },
                onSkillAutocompleteMove: { offset in
                    moveSkillSuggestion(by: offset)
                },
                onSkillAutocompleteCommit: {
                    commitSelectedSkillSuggestion()
                },
                onSkillAutocompleteDismiss: {
                    activeSkillQuery = nil
                }
            )
            .frame(height: composerTextHeight)

            if composerState.draft.isEmpty && !isComposerTextComposing {
                // ComposerTextView 把 textContainerInset 归零，占位文案与正文同源，无需再补 padding。
                Text(composerPlaceholderText)
                    .font(themeStore.uiFont(.body))
                    .foregroundStyle(tokens.tertiaryText)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var composerDraftBinding: Binding<String> {
        Binding(
            get: { composerState.draft },
            set: { newValue in
                guard newValue != composerState.draft else {
                    return
                }
                composerState.draft = newValue
                clearVoiceTransientStatus()
            }
        )
    }

    @ViewBuilder
    var skillAutocompletePanel: some View {
        if activeSkillQuery != nil, !filteredSkillSuggestions.isEmpty {
            SkillAutocompletePanel(
                skills: filteredSkillSuggestions,
                selectedIndex: min(selectedSkillSuggestionIndex, filteredSkillSuggestions.count - 1),
                onSelect: { skill in
                    selectSkillFromAutocomplete(skill)
                }
            )
            .environmentObject(themeStore)
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
        }
    }

    var filteredSkillSuggestions: [SkillCapability] {
        guard let activeSkillQuery else { return [] }
        let query = activeSkillQuery.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = enabledSkillShortcuts.filter { skill in
            guard !selectedSkillPaths.contains(skill.path) else { return false }
            return query.isEmpty
                || skill.name.localizedCaseInsensitiveContains(query)
                || skill.presentationName.localizedCaseInsensitiveContains(query)
        }
        return Array(matches.prefix(5))
    }

    func moveSkillSuggestion(by offset: Int) {
        guard !filteredSkillSuggestions.isEmpty else { return }
        let count = filteredSkillSuggestions.count
        selectedSkillSuggestionIndex = (selectedSkillSuggestionIndex + offset + count) % count
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func commitSelectedSkillSuggestion() {
        guard !filteredSkillSuggestions.isEmpty else { return }
        let index = min(selectedSkillSuggestionIndex, filteredSkillSuggestions.count - 1)
        selectSkillFromAutocomplete(filteredSkillSuggestions[index])
    }

    func selectSkillFromAutocomplete(_ skill: SkillCapability) {
        guard let query = activeSkillQuery else { return }
        if let updatedText = composerTextSubmitBridge.replaceText(in: query.replacementRange, with: "") {
            composerState.draft = updatedText
        }
        addSkillAttachment(skill, closesPanel: false)
        activeSkillQuery = nil
        selectedSkillSuggestionIndex = 0
    }

    func composerCardBorderColor(_ tokens: ThemeTokens) -> Color {
        if voiceInput.isRecording {
            // 录音时只给输入框一圈很淡的主题色描边作为氛围提示，真正“正在录音”的强调交给
            // 上方那条带波形的胶囊；不再让整个输入框被强描边抢走注意力。
            return tokens.voiceRecording.opacity(0.4)
        }
        if voiceInput.isPreparing || isVoicePressActive {
            return tokens.accent.opacity(0.55)
        }
        if isVoiceTranscribing {
            return tokens.accent.opacity(0.5)
        }
        return tokens.border.opacity(0.84)
    }

    var composerPlaceholderText: String {
        if composerState.isGoalModeSelected {
            return sessionStore.selectedThreadGoal == nil ? "描述目标任务" : "要求目标后续变更"
        }
        if composerState.isPlanModeSelected {
            return "描述要先规划的问题"
        }
        if canChooseRunningFollowUpDelivery {
            return guidedFollowUpEnabled && canUseGuidedFollowUp ? "引导当前回复" : "追加下一轮指令"
        }
        if sessionStore.selectedThreadGoal != nil {
            return "要求后续变更"
        }
        return "输入任务或后续指令"
    }

    var composerCardBorderWidth: CGFloat {
        // 录音时不再加粗描边，靠颜色而非粗细提示，避免“大红框”观感；准备阶段仍略加粗。
        if voiceInput.isPreparing || isVoicePressActive {
            return 1.5
        }
        return voiceInput.isRecording ? 1.25 : 1
    }

    // 快捷行固定在输入区上方：开关在行首，选项从它右侧展开；主操作行只保留发送链路，
    // 上下两行不再有重复入口。展开与否只跟随用户偏好，与宽度无关，横竖屏表现一致。
    var composerShortcutRow: some View {
        HStack(spacing: 8) {
            shortcutBarToggle
            if prefersExpandedShortcutBar {
                // 固定宽度的快捷按钮放入横向滚动容器，内容再长也不能反向撑大 Composer。
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        skillPickerButton
                        modelPickerControl
                        permissionMenu
                        reasoningEffortMenu
                    }
                }
                .scrollIndicators(.hidden)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 快捷选项只在这一行内动画；模型、权限等值变更不触发整张输入卡重排动画。
        .animation(composerMotionAnimation, value: prefersExpandedShortcutBar)
    }

    var primaryComposerToolbar: some View {
        HStack(spacing: usesCompactComposerMetrics ? 8 : 10) {
            addContentButton
            followUpDeliveryMenu
            Spacer(minLength: 0)
            composerOptionsMenu
            voiceMicControl
            sendButton(showLabels: !usesCompactComposerMetrics)
        }
        .frame(maxWidth: .infinity)
    }

    var shortcutBarToggle: some View {
        Button {
            prefersExpandedShortcutBar.toggle()
            if !prefersExpandedShortcutBar {
                showsSkillPicker = false
                showsModelGridPicker = false
            }
        } label: {
            composerToolbarControlLabel(
                title: "快捷",
                systemImage: prefersExpandedShortcutBar ? "chevron.left" : "chevron.right",
                isSelected: prefersExpandedShortcutBar,
                accessibilityLabel: prefersExpandedShortcutBar ? "收起快捷按钮" : "展开快捷按钮"
            )
        }
        .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(prefersExpandedShortcutBar ? "收起快捷按钮" : "展开快捷按钮")
    }

    var composerOptionsMenu: some View {
        // 模型、权限、推理强度已由输入区上方的快捷行承担，这里不再重复入口，
        // 只保留低频运行参数和发送模式，避免同一屏幕出现两套配置面。
        Menu {
            runSettingsMenu

            Divider()

            Button {
                setSendMode(composerState.isPlanModeSelected ? .standard : .plan)
            } label: {
                Label(composerState.isPlanModeSelected ? "关闭计划模式" : "计划模式", systemImage: composerState.isPlanModeSelected ? "checkmark" : "list.clipboard")
            }

            Button {
                setSendMode(composerState.isGoalModeSelected ? .standard : .goal)
            } label: {
                Label(composerState.isGoalModeSelected ? "关闭目标任务" : "目标任务", systemImage: composerState.isGoalModeSelected ? "checkmark" : "target")
            }
        } label: {
            composerToolbarControlLabel(
                title: usesCompactComposerMetrics ? nil : "选项",
                systemImage: "slider.horizontal.3",
                isSelected: composerState.isPlanModeSelected || composerState.isGoalModeSelected,
                accessibilityLabel: "会话选项"
            )
        }
        .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("会话选项")
        .accessibilityHint("调整生成设置和发送模式")
    }

    var voiceMicControl: some View {
        VoiceMicButton(
            isPreparing: voiceInput.isPreparing || (isVoicePressActive && !voiceInput.isRecording),
            isRecording: voiceInput.isRecording,
            isTranscribing: isVoiceTranscribing,
            onTap: {
                toggleVoiceInput()
            }
        )
        .layoutPriority(0)
    }

    var voiceKeyboardShortcutButton: some View {
        Button {
            toggleVoiceInputFromKeyboard()
        } label: {
            EmptyView()
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityLabel(voiceInput.isRecording || isVoicePressActive || isVoiceTranscribing ? "结束语音输入" : "开始语音输入")
        .accessibilityHidden(true)
    }

    var composerKeyboardShortcutButtons: some View {
        ZStack {
            hiddenKeyboardShortcut("打开命令面板", key: "k", modifiers: [.command]) {
                showsAddContentPanel = true
            }
            hiddenKeyboardShortcut("打开引用面板", key: "k", modifiers: [.command, .shift]) {
                showsAddContentPanel = true
            }
            hiddenKeyboardShortcut("切换目标任务模式", key: "g", modifiers: [.command, .shift]) {
                setSendMode(composerState.isGoalModeSelected ? .standard : .goal)
            }
            hiddenKeyboardShortcut("切换计划模式", key: "p", modifiers: [.command, .shift]) {
                setSendMode(composerState.isPlanModeSelected ? .standard : .plan)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    func hiddenKeyboardShortcut(
        _ title: String,
        key: Character,
        modifiers: EventModifiers,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            EmptyView()
        }
        .keyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .accessibilityLabel(title)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    var addContentButton: some View {
        Button {
            showsAddContentPanel.toggle()
        } label: {
            composerToolbarControlLabel(
                title: nil,
                systemImage: "plus",
                accessibilityLabel: "添加内容"
            )
        }
        .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("添加内容")
        .help("添加图片、@ 插件、Skill 或快捷短语")
        .popover(isPresented: $showsAddContentPanel, arrowEdge: .bottom) {
            AddContentPanel(
                skillShortcuts: enabledSkillShortcuts,
                pluginShortcuts: installedPluginShortcuts,
                capabilityErrorMessage: sessionStore.capabilityErrorMessage,
                isRefreshingCapabilities: sessionStore.isRefreshingCapabilities,
                onPickPhotos: {
                    presentPhotoLibraryPicker()
                },
                onSkillShortcut: { skill in
                    addSkillAttachment(skill)
                },
                onPluginShortcut: { plugin in
                    composerState.insertPluginMention(plugin.presentationName)
                    clearVoiceTransientStatus()
                    showsAddContentPanel = false
                    UISelectionFeedbackGenerator().selectionChanged()
                },
                onRefreshCapabilities: {
                    Task { await sessionStore.refreshCapabilities() }
                },
                onShortcut: { shortcut in
                    composerState.insertShortcut(shortcut)
                    clearVoiceTransientStatus()
                    showsAddContentPanel = false
                }
            )
            .environmentObject(themeStore)
            .presentationCompactAdaptation(.sheet)
        }
    }

    var skillPickerButton: some View {
        Button {
            showsSkillPicker.toggle()
        } label: {
            composerToolbarControlLabel(
                title: "Skill",
                systemImage: "wand.and.stars",
                isSelected: !selectedSkillPaths.isEmpty,
                accessibilityLabel: "选择 Skill"
            )
        }
        .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("选择 Skill")
        .accessibilityValue(selectedSkillPaths.isEmpty ? "未选择" : "已选择 \(selectedSkillPaths.count) 个")
        .help("选择 Skill，或在输入框键入 $ 快速调用")
        .popover(isPresented: $showsSkillPicker, arrowEdge: .bottom) {
            SkillPickerPanel(
                skills: enabledSkillShortcuts,
                selectedPaths: selectedSkillPaths,
                errorMessage: sessionStore.capabilityErrorMessage,
                isRefreshing: sessionStore.isRefreshingCapabilities,
                onToggle: { skill in
                    toggleSkillAttachment(skill)
                },
                onRefresh: {
                    Task { await sessionStore.refreshCapabilities() }
                },
                onManualAdd: {
                    showsSkillPicker = false
                    showsManualSkillInputSheet = true
                }
            )
            .environmentObject(themeStore)
            .presentationCompactAdaptation(.sheet)
        }
    }

    var enabledSkillShortcuts: [SkillCapability] {
        // 菜单直接消费 agentd capabilities，避免写死技能短语；排序后截断，保证菜单稳定且不拖慢 body。
        (sessionStore.capabilityList?.skills ?? [])
            .filter(\.enabled)
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var installedPluginShortcuts: [CodexPluginCapability] {
        (sessionStore.capabilityList?.plugins ?? [])
            .sorted { lhs, rhs in
                if lhs.enabled != rhs.enabled {
                    return lhs.enabled && !rhs.enabled
                }
                return lhs.presentationName.localizedStandardCompare(rhs.presentationName) == .orderedAscending
            }
    }

    var selectedSkillPaths: Set<String> {
        Set(composerState.attachments.compactMap { item in
            guard case .skill(_, let path) = item else { return nil }
            return path
        })
    }

    func addSkillAttachment(_ skill: SkillCapability, closesPanel: Bool = true) {
        guard !selectedSkillPaths.contains(skill.path) else {
            if closesPanel {
                showsAddContentPanel = false
            }
            return
        }
        composerState.addAttachment(.skill(name: skill.name, path: skill.path))
        clearVoiceTransientStatus()
        if closesPanel {
            showsAddContentPanel = false
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func toggleSkillAttachment(_ skill: SkillCapability) {
        if let index = composerState.attachments.firstIndex(where: { item in
            guard case .skill(_, let path) = item else { return false }
            return path == skill.path
        }) {
            composerState.removeAttachment(at: index)
            UISelectionFeedbackGenerator().selectionChanged()
        } else {
            addSkillAttachment(skill, closesPanel: false)
        }
    }

    func setSendMode(_ mode: ComposerSendMode) {
        composerState.setSendMode(mode)
        let scope = activeComposerDraftScope == .none ? currentComposerDraftScope : activeComposerDraftScope
        persistComposerSendMode(mode, for: scope)
    }

    func composerToolbarControlLabel(
        title: String?,
        systemImage: String,
        isSelected: Bool = false,
        tint: Color? = nil,
        titleMaxWidth: CGFloat? = nil,
        accessibilityLabel: String
    ) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let foreground = isSelected ? tokens.primaryActionForeground : (tint ?? tokens.accent)

        return HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 14, weight: .semibold))
            if let title {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: titleMaxWidth, alignment: .leading)
            }
        }
        .font(themeStore.uiFont(.caption, weight: .semibold))
        .foregroundStyle(foreground)
        .frame(height: 44)
        .padding(.horizontal, title == nil ? 0 : 12)
        .frame(minWidth: 44)
        .background(
            isSelected ? tokens.accent : tokens.elevatedSurface,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            if !isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tokens.border.opacity(0.9), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    var followUpDeliveryMenu: some View {
        if canChooseRunningFollowUpDelivery {
            let tokens = themeStore.tokens(for: colorScheme)
            let isGuidedAvailable = canUseGuidedFollowUp
            let isGuidedSelected = guidedFollowUpEnabled && isGuidedAvailable
            Menu {
                Section("发送方式") {
                    Button {
                        selectFollowUpDelivery(guided: false)
                    } label: {
                        Label("排队（默认）", systemImage: isGuidedSelected ? "clock" : "checkmark")
                    }
                    Button {
                        selectFollowUpDelivery(guided: true)
                    } label: {
                        Label(isGuidedAvailable ? "引导当前回复" : "引导当前回复（当前无活动回合）", systemImage: isGuidedSelected ? "checkmark" : "text.bubble")
                    }
                    .disabled(!isGuidedAvailable)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isGuidedSelected ? "text.bubble.fill" : "clock")
                        .font(themeStore.uiFont(size: 15, weight: .bold))
                    if !usesCompactComposerMetrics {
                        Text(isGuidedSelected ? "引导" : "排队")
                            .font(themeStore.uiFont(.callout, weight: .semibold))
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.up")
                        .font(themeStore.uiFont(size: 10, weight: .bold))
                        .opacity(0.72)
                }
                .foregroundStyle(isGuidedSelected ? tokens.accent : tokens.primaryText)
                .frame(height: 44)
                .padding(.horizontal, usesCompactComposerMetrics ? 0 : 11)
                .frame(minWidth: usesCompactComposerMetrics ? 44 : 76)
                .background(
                    isGuidedSelected ? tokens.accent.opacity(0.12) : tokens.elevatedSurface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isGuidedSelected ? tokens.accent.opacity(0.42) : tokens.border)
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
            .help(isGuidedSelected ? "立即改变当前正在生成的回复" : "先保存在此设备，当前回复完成后自动发送为下一轮")
            .accessibilityLabel("运行中追加方式")
            .accessibilityValue(isGuidedSelected ? "引导当前回复" : "排队下一轮")
            .accessibilityHint("点按可切换排队或引导当前回复")
        }
    }

    func selectFollowUpDelivery(guided: Bool) {
        guard !guided || canUseGuidedFollowUp else {
            return
        }
        guard guidedFollowUpEnabled != guided else {
            return
        }
        guidedFollowUpEnabled = guided
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @ViewBuilder
    var voiceReviewNotice: some View {
        if composerState.voiceDraftNeedsReview {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield")
                Text("语音草稿待确认")
                    .lineLimit(1)
            }
            .font(themeStore.uiFont(.caption, weight: .medium))
            .foregroundStyle(themeStore.tokens(for: colorScheme).accent)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(themeStore.tokens(for: colorScheme).accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(themeStore.tokens(for: colorScheme).accent.opacity(0.35))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var runSettingsMenu: some View {
        Menu {
            serviceTierOptionsMenu
            outputOptionsMenu
            if developerModeEnabled {
                Divider()
                Button {
                    showsAdvancedOptionsSheet = true
                } label: {
                    Label("高级选项", systemImage: "ellipsis.circle")
                }
            }
        } label: {
            composerToolbarControlLabel(
                title: "生成",
                systemImage: "gearshape",
                accessibilityLabel: "生成设置"
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("生成设置")
        .accessibilityHint("调整速度和输出")
    }

    @ViewBuilder
    var modelPickerControl: some View {
        if selectedSessionRuntimeProviderForModelMenu == "claude" {
            modelOptionsMenu
        } else {
            Button {
                showsModelGridPicker.toggle()
            } label: {
                composerToolbarControlLabel(
                    title: modelPickerTriggerTitle,
                    systemImage: "cpu",
                    titleMaxWidth: 150,
                    accessibilityLabel: "切换模型与推理强度"
                )
                .contentTransition(.opacity)
            }
            .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
            .accessibilityLabel("切换模型与推理强度")
            .accessibilityValue(modelPickerTriggerTitle)
            .accessibilityHint("打开三乘三模型选择器，可沿两个方向滑动")
            .popover(isPresented: $showsModelGridPicker, arrowEdge: .bottom) {
                ModelReasoningGridPicker(
                    options: modelOptionsForMenu,
                    selection: selectedModelGridSelection,
                    selectedModelID: composerState.turnOptions.model,
                    isRefreshing: sessionStore.isRefreshingAppServerModels,
                    onSelect: { option, effort in
                        selectGridModel(option, effort: effort)
                    },
                    onSelectModelOnly: { option in
                        selectModelOnly(option)
                    },
                    onRefresh: {
                        Task { await sessionStore.refreshAppServerModelOptions(force: true) }
                    }
                )
                .environmentObject(themeStore)
                .presentationCompactAdaptation(.sheet)
            }
        }
    }

    var modelOptionsMenu: some View {
        Menu {
            modelOptionItems
        } label: {
            composerToolbarControlLabel(
                title: selectedModelSummaryTitle,
                systemImage: "cpu",
                titleMaxWidth: 140,
                accessibilityLabel: "切换模型"
            )
        }
        .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("切换模型")
        .accessibilityValue(selectedModelSummaryTitle)
        .accessibilityHint("选择下一轮使用的模型")
    }

    var selectedModelGridSelection: GPT56ModelGridSelection {
        let rows = GPT56ModelGridCatalog.rows(from: modelOptionsForMenu)
        let selectedID = composerState.turnOptions.model
        let option = rows.first(where: { $0.model == selectedID })
            ?? rows.first(where: \.isDefault)
            ?? rows.first
        let effort = composerState.turnOptions.reasoningEffort.flatMap { selected in
            GPT56ModelGridCatalog.efforts.contains(selected) ? selected : nil
        } ?? option.flatMap { option in
            option.defaultReasoningEffort.flatMap(CodexAppServerReasoningEffort.init(rawValue:))
        } ?? .medium
        return GPT56ModelGridSelection(
            modelID: option?.model ?? "gpt-5.6-sol",
            effort: effort
        )
    }

    var modelPickerTriggerTitle: String {
        guard let selectedModel = composerState.turnOptions.model,
              GPT56ModelGridCatalog.modelOrder.contains(selectedModel.lowercased())
        else {
            return selectedModelSummaryTitle
        }
        let model = GPT56ModelGridCatalog.shortTitle(for: selectedModel)
        let effort = composerState.turnOptions.reasoningEffort ?? selectedModelGridSelection.effort
        return "5.6 \(model) · \(GPT56ModelGridCatalog.effortTitle(effort))"
    }

    func selectGridModel(_ option: CodexAppServerModelOption, effort: CodexAppServerReasoningEffort) {
        composerState.updateTurnOptions { options in
            options.runtimeProvider = option.runtimeProvider
            options.model = option.model
            options.modelProvider = option.provider
            options.reasoningEffort = effort
        }
    }

    func selectModelOnly(_ option: CodexAppServerModelOption?) {
        composerState.updateTurnOptions { options in
            options.runtimeProvider = option?.runtimeProvider ?? payloadRuntimeProviderForSelectedSessionLock()
            options.model = option?.model
            options.modelProvider = option?.provider
            if let defaultEffort = option?.defaultReasoningEffort.flatMap(CodexAppServerReasoningEffort.init(rawValue:)) {
                options.reasoningEffort = defaultEffort
            }
        }
    }

    @ViewBuilder
    var modelOptionItems: some View {
        Button {
            composerState.updateTurnOptions { options in
                options.runtimeProvider = payloadRuntimeProviderForSelectedSessionLock()
                options.model = nil
                options.modelProvider = nil
            }
        } label: {
            Label("默认 · \(defaultModelSummaryTitle)", systemImage: composerState.turnOptions.model == nil ? "checkmark" : "cpu")
        }
        ForEach(modelOptionsForMenu) { option in
            let isSelected = isSelectedModelOption(option)
            Button {
                composerState.updateTurnOptions { options in
                    options.runtimeProvider = option.runtimeProvider
                    options.model = option.model
                    options.modelProvider = option.provider
                }
            } label: {
                Label(option.menuTitle, systemImage: isSelected ? "checkmark" : "cpu")
            }
        }
        Divider()
        Button {
            Task { await sessionStore.refreshAppServerModelOptions(force: true) }
        } label: {
            Label(sessionStore.isRefreshingAppServerModels ? "刷新中" : "刷新模型列表", systemImage: "arrow.clockwise")
        }
        .disabled(sessionStore.isRefreshingAppServerModels)
    }

    var reasoningEffortMenu: some View {
        Menu {
            reasoningEffortOptions
        } label: {
            composerToolbarControlLabel(
                title: "推理 · \(reasoningEffortTitle)",
                systemImage: "brain.head.profile",
                accessibilityLabel: "推理强度"
            )
        }
        .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("推理强度")
        .accessibilityValue(reasoningEffortTitle)
        .accessibilityHint("选择下一轮回答的思考深度")
        .help("推理强度：\(reasoningEffortTitle)")
    }

    @ViewBuilder
    var reasoningEffortOptions: some View {
        Button {
            composerState.updateTurnOptions { $0.reasoningEffort = nil }
        } label: {
            Label("默认", systemImage: composerState.turnOptions.reasoningEffort == nil ? "checkmark" : "brain.head.profile")
        }
        ForEach(CodexAppServerReasoningEffort.allCases) { effort in
            Button {
                composerState.updateTurnOptions { $0.reasoningEffort = effort }
            } label: {
                Label(
                    reasoningEffortTitle(for: effort),
                    systemImage: composerState.turnOptions.reasoningEffort == effort ? "checkmark" : "brain.head.profile"
                )
            }
        }
    }

    var reasoningEffortTitle: String {
        composerState.turnOptions.reasoningEffort.map { reasoningEffortTitle(for: $0) } ?? "默认"
    }

    func reasoningEffortTitle(for effort: CodexAppServerReasoningEffort) -> String {
        switch effort {
        case .none:
            return "关闭"
        case .minimal:
            return "最低"
        case .low:
            return "低"
        case .medium:
            return "中"
        case .high:
            return "高"
        case .xhigh:
            return "极高"
        }
    }

    var serviceTierOptionsMenu: some View {
        Menu {
            Button("默认") { composerState.updateTurnOptions { $0.serviceTier = nil } }
            Button("auto") { composerState.updateTurnOptions { $0.serviceTier = "auto" } }
            Button("priority") { composerState.updateTurnOptions { $0.serviceTier = "priority" } }
            Button("flex") { composerState.updateTurnOptions { $0.serviceTier = "flex" } }
        } label: {
            Label(composerState.turnOptions.serviceTier ?? "速度默认", systemImage: "speedometer")
        }
    }

    var outputOptionsMenu: some View {
        Menu {
            Section("摘要") {
                Button("默认") { composerState.updateTurnOptions { $0.reasoningSummary = nil } }
                ForEach(CodexAppServerReasoningSummary.allCases) { summary in
                    Button(summary.rawValue) { composerState.updateTurnOptions { $0.reasoningSummary = summary } }
                }
            }
            Section("人格") {
                Button("默认") { composerState.updateTurnOptions { $0.personality = nil } }
                Button("none") { composerState.updateTurnOptions { $0.personality = CodexAppServerPersonality.none } }
                Button("friendly") { composerState.updateTurnOptions { $0.personality = .friendly } }
                Button("pragmatic") { composerState.updateTurnOptions { $0.personality = .pragmatic } }
            }
        } label: {
            Label("摘要/人格", systemImage: "text.bubble")
        }
    }

    var permissionMenu: some View {
        Menu {
            Section("权限模式") {
                ForEach(availablePermissionModes) { mode in
                    Button {
                        setPermissionMode(mode)
                    } label: {
                        Label(
                            mode.title,
                            systemImage: composerState.permissionMode == mode ? "checkmark" : mode.systemImage
                        )
                    }
                    .accessibilityHint(mode.detail)
                }
            }
            Section("当前效果") {
                Text(composerState.permissionMode.detail)
                Text(permissionWireSummary)
            }
        } label: {
            composerToolbarControlLabel(
                title: composerState.permissionMode.title,
                systemImage: composerState.permissionMode.systemImage,
                tint: permissionTint,
                accessibilityLabel: "权限模式"
            )
        }
        .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("权限模式")
        .accessibilityValue(permissionTitle)
    }

    // 录音/准备/转写的实时状态，作为状态行中段的胶囊。波形单独订阅 levelMeter，
    // 不会带动整条 ComposerView 重绘。紧凑布局（iPhone/窄分屏）下只留波形、隐去文案，避免一行挤不下。
    @ViewBuilder
    var voiceWaveformContent: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        if isVoiceTranscribing {
            voiceActivityCapsule(tint: tokens.accent) {
                ProgressView()
                    .controlSize(.small)
                    .tint(tokens.accent)
                if !usesCompactComposerMetrics {
                    Text("模型转写中")
                        .lineLimit(1)
                }
            }
        } else if voiceInput.isRecording {
            voiceActivityCapsule(tint: tokens.voiceRecording, emphasized: true) {
                VoiceWaveformView(meter: voiceInput.levelMeter, isActive: true, colors: tokens.voiceWaveformGradient)
                    .frame(width: usesCompactComposerMetrics ? 124 : 190, height: usesCompactComposerMetrics ? 32 : 34)
                if !usesCompactComposerMetrics {
                    Text("正在听，松手转写")
                        .lineLimit(1)
                }
            }
        } else if voiceInput.isPreparing || isVoicePressActive {
            voiceActivityCapsule(tint: tokens.accent) {
                ProgressView()
                    .controlSize(.small)
                    .tint(tokens.accent)
                if !usesCompactComposerMetrics {
                    Text("正在准备…")
                        .lineLimit(1)
                }
            }
        }
    }

    func voiceActivityCapsule<Content: View>(
        tint: Color,
        emphasized: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .font(themeStore.uiFont(.caption, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .frame(height: emphasized ? 40 : 36)
        .background(tint.opacity(emphasized ? 0.12 : 0.1), in: Capsule())
        .overlay {
            Capsule().strokeBorder(tint.opacity(emphasized ? 0.4 : 0.32))
        }
        .shadow(color: emphasized ? tint.opacity(0.12) : .clear, radius: 8, y: 2)
        .fixedSize(horizontal: true, vertical: false)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    var modelOptionsForMenu: [CodexAppServerModelOption] {
        let source = sessionStore.appServerModelOptions.isEmpty ? CodexAppServerModelOption.builtInFallback : sessionStore.appServerModelOptions
        let options = source.filter { !$0.hidden }
        guard let runtimeProvider = selectedSessionRuntimeProviderForModelMenu else {
            return options
        }
        let scoped = options.filter { option in
            normalizedRuntimeProvider(option.runtimeProvider) == runtimeProvider
        }
        if scoped.isEmpty, runtimeProvider == "claude" {
            return CodexAppServerModelOption.builtInClaudeFallback
        }
        if scoped.isEmpty, runtimeProvider == "codex" {
            return CodexAppServerModelOption.builtInFallback
        }
        return scoped.isEmpty ? options : scoped
    }

    func applyDefaultPermissionMode() {
        let stored = ComposerPermissionMode.stored(defaultPermissionModeID)
        composerState.applyPermissionMode(safePermissionMode(stored))
    }

    func setPermissionMode(_ mode: ComposerPermissionMode) {
        let safeMode = safePermissionMode(mode)
        // Claude 的安全降级只影响当前会话，不覆盖用户为 Codex 保存的“完全访问”默认值。
        if selectedSessionRuntimeProviderForModelMenu != "claude" {
            defaultPermissionModeID = safeMode.rawValue
        }
        composerState.applyPermissionMode(safeMode)
    }

    var availablePermissionModes: [ComposerPermissionMode] {
        if selectedSessionRuntimeProviderForModelMenu == "claude" {
            return [.requestApproval, .readOnly, .autoApprove]
        }
        return ComposerPermissionMode.allCases
    }

    func safePermissionMode(_ mode: ComposerPermissionMode) -> ComposerPermissionMode {
        selectedSessionRuntimeProviderForModelMenu == "claude" && mode == .fullAccess
            ? .requestApproval
            : mode
    }

    func clampPermissionSelectionToSelectedSessionRuntime() {
        let safeMode = safePermissionMode(composerState.permissionMode)
        guard safeMode != composerState.permissionMode else {
            return
        }
        composerState.applyPermissionMode(safeMode)
    }

    var selectedModelSummaryTitle: String {
        guard let model = composerState.turnOptions.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            return defaultModelSummaryTitle
        }
        if let option = modelOptionsForMenu.first(where: { item in
            item.model == model &&
                item.runtimeProvider == composerState.turnOptions.runtimeProvider &&
                (composerState.turnOptions.modelProvider == nil || item.provider == composerState.turnOptions.modelProvider)
        }) {
            return developerModeEnabled ? option.menuTitle : option.title
        }
        if developerModeEnabled, let provider = composerState.turnOptions.modelProvider?.trimmingCharacters(in: .whitespacesAndNewlines), !provider.isEmpty {
            return "\(model) · \(provider)"
        }
        return model
    }

    func isSelectedModelOption(_ option: CodexAppServerModelOption) -> Bool {
        guard let selectedModel = composerState.turnOptions.model else {
            return false
        }
        return option.model == selectedModel &&
            option.runtimeProvider == composerState.turnOptions.runtimeProvider &&
            (composerState.turnOptions.modelProvider == nil || option.provider == composerState.turnOptions.modelProvider)
    }

    var defaultModelSummaryTitle: String {
        guard let option = modelOptionsForMenu.first(where: \.isDefault) ?? modelOptionsForMenu.first else {
            return "默认模型"
        }
        return developerModeEnabled ? option.menuTitle : option.title
    }

    var selectedSessionRuntimeProviderForModelMenu: String? {
        guard let session = sessionStore.selectedSession else {
            return nil
        }
        if session.source == "local", session.runtimeProvider == nil {
            return nil
        }
        return normalizedRuntimeProvider(session.runtimeProvider ?? session.source)
    }

    func clampModelSelectionToSelectedSessionRuntime() {
        guard let runtimeProvider = selectedSessionRuntimeProviderForModelMenu else {
            return
        }
        guard normalizedRuntimeProvider(composerState.turnOptions.runtimeProvider) != runtimeProvider else {
            return
        }
        composerState.updateTurnOptions { options in
            options.runtimeProvider = payloadRuntimeProviderForSelectedSessionLock()
            options.model = nil
            options.modelProvider = nil
        }
    }

    func payloadRuntimeProviderForSelectedSessionLock() -> String? {
        guard let runtimeProvider = selectedSessionRuntimeProviderForModelMenu else {
            return nil
        }
        return runtimeProvider == "codex" ? nil : runtimeProvider
    }

    func normalizedRuntimeProvider(_ rawValue: String?) -> String {
        CodexAppServerSessionRuntime.normalizedRuntimeProvider(rawValue)
    }

}
