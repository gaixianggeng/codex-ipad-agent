import AVFoundation
import AudioToolbox
import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct ComposerChipItem: Identifiable {
    let id: String
    let text: String
    let symbol: String
    let tint: Color
}

enum VoiceInputLanguage: String, CaseIterable, Identifiable {
    case automatic
    case chineseSimplified
    case englishUS
    case japanese
    case korean

    static let storageKey = "voice.input.language"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "自动"
        case .chineseSimplified:
            return "中文"
        case .englishUS:
            return "English"
        case .japanese:
            return "日本語"
        case .korean:
            return "한국어"
        }
    }

    var localeCandidates: [Locale] {
        switch self {
        case .automatic:
            return [Locale(identifier: "zh_CN"), Locale.current]
        case .chineseSimplified:
            return [Locale(identifier: "zh_CN"), Locale.current]
        case .englishUS:
            return [Locale(identifier: "en_US"), Locale.current]
        case .japanese:
            return [Locale(identifier: "ja_JP"), Locale.current]
        case .korean:
            return [Locale(identifier: "ko_KR"), Locale.current]
        }
    }

    var transcriptionLanguageCode: String? {
        switch self {
        case .automatic:
            return nil
        case .chineseSimplified:
            return "zh"
        case .englishUS:
            return "en"
        case .japanese:
            return "ja"
        case .korean:
            return "ko"
        }
    }

    var transcriptionPrompt: String {
        switch self {
        case .automatic:
            return "这是一段给编程助手的口述指令，请准确转写，保留原始语言、技术术语和自然标点。"
        case .chineseSimplified:
            return "这是一段中文口述给编程助手的指令，请准确转写，保留技术术语、英文词和自然标点。"
        case .englishUS:
            return "This is an English dictated instruction to a coding assistant. Preserve technical terms and natural punctuation."
        case .japanese:
            return "これはコーディング支援への日本語の音声指示です。技術用語と自然な句読点を保って正確に書き起こしてください。"
        case .korean:
            return "코딩 도우미에게 말한 한국어 음성 지시입니다. 기술 용어와 자연스러운 문장 부호를 유지해 정확히 받아써 주세요."
        }
    }

    static func stored(_ rawValue: String) -> VoiceInputLanguage {
        VoiceInputLanguage(rawValue: rawValue) ?? .automatic
    }
}

private struct ComposerCardHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ComposerView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var composerState = ComposerState()
    @State private var activeComposerDraftScope = ComposerDraftScopeKey.none
    @State private var composerDraftCache = ComposerDraftCache()
    @State private var composerTextExternalRevision = 0
    @StateObject private var voiceInput = VoiceInputController()
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var manualInputKind: ManualInputKind = .localImage
    @State private var showsAddContentPanel = false
    @State private var showsManualInputSheet = false
    @State private var showsAdvancedOptionsSheet = false
    @State private var showsImageFileImporter = false
    @State private var previewingAttachment: CodexAppServerUserInput?
    @State private var goalEditor: ThreadGoalEditorDraft?
    @State private var isGoalStatusExpanded = false
    @State private var hiddenCompletedGoalIDs: Set<SessionID> = []
    @State private var attachmentErrorMessage: String?
    @State private var isVoicePressActive = false
    @State private var isVoiceTranscribing = false
    @State private var voiceTranscriptionTask: Task<Void, Never>?
    @State private var activeVoiceTranscriptionContext: VoiceTranscriptionContext?
    @State private var voicePressStartedAt: Date?
    @State private var retryableVoiceTranscription: RetryableVoiceTranscription?
    @State private var measuredComposerTextHeight: CGFloat = 0
    @State private var measuredComposerCardHeight: CGFloat = 0
    @State private var isComposerTextComposing = false
    @State private var composerTextSubmitBridge = ComposerTextSubmitBridge()
    @AppStorage("agentd.developerMode") private var developerModeEnabled = false
    @AppStorage(ComposerPermissionMode.defaultStorageKey) private var defaultPermissionModeID = ComposerPermissionMode.defaultMode.rawValue
    @State private var guidedFollowUpEnabled = false
    @AppStorage(VoiceInputLanguage.storageKey) private var selectedVoiceLanguageID = VoiceInputLanguage.automatic.rawValue

    var availableWidth: CGFloat?

    init(availableWidth: CGFloat? = nil, initialGoalStatusExpanded: Bool = false) {
        self.availableWidth = availableWidth
        _isGoalStatusExpanded = State(initialValue: initialGoalStatusExpanded)
    }

    private static let minimumUsableVoiceDuration: TimeInterval = 0.35
    private static let minimumVoicePressDuration: TimeInterval = 0.45
    private static let completedGoalAutoHideDelayNanoseconds: UInt64 = 3_500_000_000

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        // 外层不再画大方框：ConversationView 的底部 dock 已经提供了表面色和顶部分隔线，
        // 这里只保留一个真正的输入卡片，避免“框中框”的视觉堆叠。
        VStack(alignment: .leading, spacing: 10) {
            foregroundActivityRow
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
        .animation(.easeInOut(duration: 0.18), value: voiceInput.isRecording)
        .animation(.easeInOut(duration: 0.18), value: voiceInput.isPreparing)
        .animation(.easeInOut(duration: 0.18), value: isVoicePressActive)
        .animation(.easeInOut(duration: 0.18), value: isVoiceTranscribing)
        .sheet(isPresented: $showsManualInputSheet) {
            ManualUserInputSheet(kind: manualInputKind) { input in
                composerState.addAttachment(input)
            }
        }
        .sheet(isPresented: $showsAdvancedOptionsSheet) {
            AdvancedTurnOptionsSheet(options: composerState.turnOptions) { options in
                composerState.turnOptions = options
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
        .fileImporter(isPresented: $showsImageFileImporter, allowedContentTypes: [.image]) { result in
            showsAddContentPanel = false
            switch result {
            case .success(let url):
                loadImageFileAttachment(url)
            case .failure(let error):
                attachmentErrorMessage = userFacingAttachmentError(error)
            }
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else {
                return
            }
            showsAddContentPanel = false
            loadPhotoAttachment(item)
        }
        .onChange(of: developerModeEnabled) { _, enabled in
            guard !enabled else {
                return
            }
            composerState.turnOptions = composerState.turnOptions.sanitizedForStandardComposer()
            showsAdvancedOptionsSheet = false
        }
        .onChange(of: defaultPermissionModeID) { _, _ in
            applyDefaultPermissionMode()
        }
        .onChange(of: selectedVoiceLanguageID) { _, _ in
            clearVoiceTransientStatus()
        }
        .onChange(of: currentComposerDraftScope) { _, newScope in
            switchComposerDraftScope(to: newScope)
        }
        .onChange(of: selectedSessionRuntimeProviderForModelMenu) { _, _ in
            clampModelSelectionToSelectedSessionRuntime()
        }
        .onChange(of: canUseGuidedFollowUp) { _, canGuide in
            if !canGuide {
                guidedFollowUpEnabled = false
            }
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
            cancelVoiceInteraction(clearStatus: true)
        }
    }

    @discardableResult
    private func submitDraft() -> Bool {
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
        composerDraftCache.remove(scope: submittedDraftScope)
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
                    composerDraftCache.remove(scope: submittedDraftScope)
                    guidedFollowUpEnabled = false
                    composerState.resetSendModeAfterSubmit()
                }
            }
        }
        return true
    }

    @discardableResult
    private func submitGoalDraft() -> Bool {
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
        composerDraftCache.remove(scope: submittedDraftScope)
        let objective = submitted.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else {
            composerState.restore(submitted)
            composerDraftCache.save(composerState.draftSnapshot(), for: submittedDraftScope)
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
                    composerDraftCache.remove(scope: submittedDraftScope)
                    guidedFollowUpEnabled = false
                    composerState.resetSendModeAfterSubmit()
                }
            }
        }
        return true
    }

    private func synchronizeComposerTextBeforeSubmit() -> Bool {
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

    private var currentComposerDraftScope: ComposerDraftScopeKey {
        ComposerDraftScopeKey.current(
            selectedSessionID: sessionStore.selectedSessionID,
            selectedProjectID: sessionStore.selectedProjectID
        )
    }

    private func switchComposerDraftScope(to nextScope: ComposerDraftScopeKey) {
        guard activeComposerDraftScope != nextScope else {
            return
        }
        synchronizeComposerTextBeforeDraftScopeChange()
        composerDraftCache.save(composerState.draftSnapshot(), for: activeComposerDraftScope)
        cancelVoiceInteraction(clearStatus: true)

        // 草稿跟会话走；运行参数仍维持全局体验，只重置下一次发送这种临时开关。
        composerState.resetTransientSendMode()
        applyDefaultPermissionMode()
        composerState.restoreDraftSnapshot(composerDraftCache.snapshot(for: nextScope))
        composerTextExternalRevision += 1
        activeComposerDraftScope = nextScope
        guidedFollowUpEnabled = false
        measuredComposerTextHeight = 0
        measuredComposerCardHeight = 0
        isComposerTextComposing = false
    }

    private func synchronizeComposerTextBeforeDraftScopeChange() {
        guard let snapshot = composerTextSubmitBridge.snapshotForSubmit() else {
            return
        }
        guard !snapshot.isComposing else {
            // marked text 还在输入法候选态，不能当成已确认草稿跨会话保存。
            isComposerTextComposing = true
            return
        }
        if composerState.draft != snapshot.text {
            composerState.draft = snapshot.text
        }
        if isComposerTextComposing {
            isComposerTextComposing = false
        }
    }

    @MainActor
    private func restoreSubmittedDraft(_ submitted: SubmittedComposerDraft, originalScope: ComposerDraftScopeKey) {
        let restoreScope = submittedDraftRestoreScope(originalScope: originalScope)
        if restoreScope == activeComposerDraftScope {
            composerState.restore(submitted)
        } else {
            composerDraftCache.save(ComposerDraftSnapshot(submitted: submitted), for: restoreScope)
        }
    }

    private func submittedDraftRestoreScope(originalScope: ComposerDraftScopeKey) -> ComposerDraftScopeKey {
        // 新建会话提交时会先进入 local:<project>:<client_message_id> 乐观会话；
        // 如果创建失败，草稿应回到这个用户正在看的失败会话，而不是藏回项目入口。
        if case .session(let sessionID) = activeComposerDraftScope,
           sessionID.hasPrefix("local:") || sessionStore.selectedSession?.source == "local" {
            return activeComposerDraftScope
        }
        return originalScope
    }

    private func preparedTurnOptionsForSubmit() -> CodexAppServerTurnOptions {
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

    private var canChooseRunningFollowUpDelivery: Bool {
        guard let session = sessionStore.selectedSession else {
            return false
        }
        return session.isRunning &&
            composerState.sendMode == .standard &&
            sessionStore.canControlSession(session)
    }

    private var canUseGuidedFollowUp: Bool {
        guard let session = sessionStore.selectedSession else {
            return false
        }
        return canChooseRunningFollowUpDelivery && session.activeTurnID != nil
    }

    private var runningTurnDeliveryForSubmit: RunningTurnDelivery {
        composerState.runningTurnDelivery(
            canUseGuidedFollowUp: canUseGuidedFollowUp,
            guidedFollowUpEnabled: guidedFollowUpEnabled
        )
    }

    private var canSubmitDraft: Bool {
        guard !isComposerTextComposing else {
            return false
        }
        if composerState.isGoalModeSelected {
            return canSubmitGoalDraft
        }
        return sessionStore.canSendInSelectedSession && composerState.canSubmit(isLoading: sessionStore.isLoading)
    }

    private var canSubmitGoalDraft: Bool {
        sessionStore.canSendInSelectedSession && composerState.hasNonWhitespaceDraft && !sessionStore.isLoading && !sessionStore.isUpdatingThreadGoal
    }

    private var isCompactComposer: Bool {
        horizontalSizeClass == .compact || (availableWidth.map { $0 < 560 } ?? false)
    }

    // 当前活动（“正在执行…”带 spinner 的标题）可能较长，单独占一行，不并入下面的状态行。
    @ViewBuilder
    private var foregroundActivityRow: some View {
        if let activity = sessionStore.selectedForegroundActivity {
            composerActivity(activity)
        }
    }

    @ViewBuilder
    private var composerStatusTray: some View {
        let visibleGoal = selectedVisibleThreadGoal
        let usageNotice = selectedComposerUsageNotice
        if sessionStore.selectedSessionControlNotice != nil ||
            sessionStore.selectedQuotaNotice != nil ||
            usageNotice != nil ||
            visibleGoal != nil {
            ComposerStatusTray(
                sessionControlNotice: sessionStore.selectedSessionControlNotice,
                quotaNotice: sessionStore.selectedQuotaNotice,
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

    private var selectedComposerUsageNotice: CodexUsageDisplaySummary? {
        guard sessionStore.selectedQuotaNotice == nil,
              let usage = sessionStore.selectedCodexUsageDisplay,
              !usage.isExhausted,
              usage.isNearLimit
        else {
            return nil
        }
        return usage
    }

    private var selectedVisibleThreadGoal: ThreadGoal? {
        guard let goal = sessionStore.selectedThreadGoal, shouldShowGoalStatusBar(goal) else {
            return nil
        }
        return goal
    }

    // 输入框上方收敛成一行：左＝常驻只读信息（模型/权限 + seq/usage 等），中＝录音波形，
    // 右＝会话运行时的 Ctrl-C / 停止。三者各就各位，不再各自独占一整行往上堆。
    @ViewBuilder
    private var composerStatusRow: some View {
        let chips = displayChipItems
        let showWave = isVoiceActive
        let showControls = canShowRunningControls
        if !chips.isEmpty || showWave || showControls {
            HStack(spacing: 10) {
                if !chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(chips) { statusChip($0) }
                        }
                        .padding(.vertical, 1)
                    }
                    .layoutPriority(0)
                }
                // 两侧都留弹性间距：波形固定在视觉中段，控制被推到最右，无论 chips 多长。
                Spacer(minLength: 8)
                if showWave {
                    voiceWaveformContent
                        .layoutPriority(1)
                }
                Spacer(minLength: 8)
                if showControls {
                    runningControls
                        .layoutPriority(1)
                }
            }
        }
    }

    private var isVoiceActive: Bool {
        voiceInput.isRecording || voiceInput.isPreparing || isVoicePressActive || isVoiceTranscribing
    }

    private var canShowRunningControls: Bool {
        sessionStore.selectedSession?.isRunning == true && sessionStore.canControlSession(sessionStore.selectedSession)
    }

    private var canInterruptSelectedSession: Bool {
        guard let session = sessionStore.selectedSession else {
            return false
        }
        return session.isRunning &&
            session.activeTurnID != nil &&
            sessionStore.canControlSession(session) &&
            sessionStore.webSocketStatus == .connected
    }

    // 常驻的只读状态标签：刻意做成扁平、中性底、小字，和底部那排“可点的” bordered 选项按钮
    // 拉开差距 —— 让用户一眼看出这只是信息展示，点不动。颜色只保留在图标上做轻提示
    // （比如“完全访问”权限的红色），文字走次要色。
    private func statusChip(_ item: ComposerChipItem) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return HStack(spacing: 4) {
            Image(systemName: item.symbol)
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(item.tint)
            Text(item.text)
                .font(themeStore.uiFont(.caption2, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tokens.surface, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    // 模型/权限等运行选项 + seq/usage 等运行时指标，都是只读展示，合并进同一组标签，
    // 顺序上让常驻的运行选项在前（最左），实时指标在后。
    private var displayChipItems: [ComposerChipItem] {
        var items = turnOptionChipItems
        for item in runtimeChipItems {
            items.append(ComposerChipItem(id: "runtime-\(item.text)", text: item.text, symbol: item.symbol, tint: item.tint))
        }
        return items
    }

    private var runningControls: some View {
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

            Button(role: .destructive) {
                Task { await sessionStore.stopSelectedSession() }
            } label: {
                Label("停止", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("停止当前会话")
        }
        .controlSize(.small)
        .font(themeStore.uiFont(.caption, weight: .medium))
        .layoutPriority(1)
    }

    private func shouldShowGoalStatusBar(_ goal: ThreadGoal) -> Bool {
        goal.status != .complete || !hiddenCompletedGoalIDs.contains(goal.threadID)
    }

    private func completedGoalAutoHideTaskID(for goal: ThreadGoal) -> String {
        [
            goal.threadID,
            goal.status.rawValue,
            goal.updatedAt.map { String($0.timeIntervalSince1970) } ?? "no-update"
        ].joined(separator: "#")
    }

    private func syncGoalStatusBarVisibility(from previousGoal: ThreadGoal?, to goal: ThreadGoal?) {
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

    private func autoHideCompletedGoalIfNeeded(_ goal: ThreadGoal) async {
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

    private func nextPrimaryGoalStatus(for status: ThreadGoalStatus) -> ThreadGoalStatus {
        switch status {
        case .active:
            return .paused
        case .paused, .blocked, .usageLimited, .budgetLimited, .complete:
            return .active
        }
    }

    private func composerInputRow(tokens: ThemeTokens) -> some View {
        HStack(alignment: .top, spacing: composerInputRowSpacing) {
            composerCard(tokens: tokens)
                .layoutPriority(1)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: ComposerCardHeightPreferenceKey.self, value: proxy.size.height)
                    }
                }

            composerVoiceActionColumn
        }
        .onPreferenceChange(ComposerCardHeightPreferenceKey.self) { height in
            guard height > 0, abs(measuredComposerCardHeight - height) > 0.5 else {
                return
            }
            // 右侧语音入口跟随输入卡片高度，保证“文字输入”和“语音输入”是同一层级的两个主入口。
            measuredComposerCardHeight = height
        }
    }

    private func composerCard(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: composerCardSpacing) {
            composerTextArea(tokens: tokens)
            voiceReviewNotice
            composerToolbar(tokens: tokens)
        }
        .padding(composerCardPadding)
        .frame(maxWidth: .infinity)
        .background(tokens.inputBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .tint(tokens.accent)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(composerCardBorderColor(tokens), lineWidth: composerCardBorderWidth)
        }
    }

    private func composerTextArea(tokens: ThemeTokens) -> some View {
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

    private var composerDraftBinding: Binding<String> {
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

    private func composerCardBorderColor(_ tokens: ThemeTokens) -> Color {
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
        return tokens.border
    }

    private var composerPlaceholderText: String {
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

    private var composerCardBorderWidth: CGFloat {
        // 录音时不再加粗描边，靠颜色而非粗细提示，避免“大红框”观感；准备阶段仍略加粗。
        if voiceInput.isPreparing || isVoicePressActive {
            return 1.5
        }
        return voiceInput.isRecording ? 1.25 : 1
    }

    private func composerToolbar(tokens: ThemeTokens) -> some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                toolbarMenuRow
                    .padding(.vertical, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            followUpDeliverySendMenu(showLabels: !isCompactComposer)
            sendButton(showLabels: !isCompactComposer)
        }
    }

    @ViewBuilder
    private var toolbarMenuRow: some View {
        HStack(spacing: 8) {
            addContentButton
            composerMoreMenu
            composerModeControls
        }
        .font(themeStore.uiFont(.caption, weight: .medium))
        .controlSize(.small)
    }

    private var composerVoiceActionColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            voiceMicControl
        }
        .frame(width: voiceActionColumnWidth, alignment: .trailing)
    }

    private var composerModeControls: some View {
        HStack(spacing: 6) {
            goalButton
            planButton
        }
    }

    private var voiceMicControl: some View {
        VoiceMicButton(
            isPreparing: voiceInput.isPreparing || (isVoicePressActive && !voiceInput.isRecording),
            isRecording: voiceInput.isRecording,
            isTranscribing: isVoiceTranscribing,
            width: voiceButtonWidth,
            height: voiceButtonHeight,
            showsTitle: voiceButtonShowsTitle,
            onPressChanged: { pressed in
                if pressed {
                    beginHoldToTalk()
                } else {
                    endHoldToTalk()
                }
            }
        )
        .layoutPriority(0)
    }

    private var voiceKeyboardShortcutButton: some View {
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

    private var composerKeyboardShortcutButtons: some View {
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

    private func hiddenKeyboardShortcut(
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
    private var addContentButton: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Button {
            showsAddContentPanel.toggle()
        } label: {
            Image(systemName: "plus")
                .font(themeStore.uiFont(size: 15, weight: .bold))
                .foregroundStyle(tokens.accent)
                .frame(width: 28, height: 28)
                .frame(width: 44, height: 44)
                .background(tokens.selectionFill, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(tokens.border.opacity(0.86), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityLabel("添加内容")
        .help("添加图片、Skill、Mention 或快捷短语")
        .popover(isPresented: $showsAddContentPanel, arrowEdge: .bottom) {
            AddContentPanel(
                selectedPhotoItem: $selectedPhotoItem,
                skillShortcuts: enabledSkillShortcuts,
                capabilityErrorMessage: sessionStore.capabilityErrorMessage,
                isRefreshingCapabilities: sessionStore.isRefreshingCapabilities,
                onPickImageFile: {
                    showsAddContentPanel = false
                    showsImageFileImporter = true
                },
                onManualInput: { kind in
                    openManualInput(kind)
                },
                onSkillShortcut: { skill in
                    addSkillAttachment(skill)
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

    @ViewBuilder
    private var composerMoreMenu: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Menu {
            permissionMenu
            runSettingsMenu
            voiceLanguageMenu
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(themeStore.uiFont(size: 15, weight: .semibold))
                .foregroundStyle(tokens.accent)
                .frame(width: 28, height: 28)
                .frame(width: 44, height: 44)
                .background(tokens.selectionFill, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(tokens.border.opacity(0.86), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityLabel("更多设置")
        .accessibilityValue(moreMenuAccessibilitySummary)
        .help("权限、运行设置和语音语言")
    }

    private var moreMenuAccessibilitySummary: String {
        "\(composerState.permissionMode.title)，运行，语音 \(selectedVoiceLanguage.title)"
    }

    private var skillShortcutMenu: some View {
        Menu {
            let skills = enabledSkillShortcuts
            if skills.isEmpty {
                if let error = sessionStore.capabilityErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                    Text("Skill 列表不可用：\(error)")
                } else {
                    Text("暂无可用 Skill")
                }
            } else {
                Section("可用 Skill") {
                    ForEach(skills.prefix(12)) { skill in
                        Button {
                            addSkillAttachment(skill)
                        } label: {
                            Label(skill.name, systemImage: "wand.and.stars")
                        }
                    }
                }
            }
            Divider()
            Button {
                Task { await sessionStore.refreshCapabilities() }
            } label: {
                Label(sessionStore.isRefreshingCapabilities ? "刷新中" : "刷新 Skill 列表", systemImage: "arrow.clockwise")
            }
            .disabled(sessionStore.isRefreshingCapabilities)
            Button {
                openManualInput(.skill)
            } label: {
                Label("手动添加 Skill", systemImage: "square.and.pencil")
            }
        } label: {
            Label("Skill", systemImage: "wand.and.stars")
                .foregroundStyle(themeStore.tokens(for: colorScheme).accent)
        }
        .buttonStyle(.bordered)
        .tint(themeStore.tokens(for: colorScheme).accent)
        .keyboardShortcut("k", modifiers: [.command, .shift])
        .help("从 capabilities.skills 一键插入 .skill(name:path)")
    }

    private var enabledSkillShortcuts: [SkillCapability] {
        // 菜单直接消费 agentd capabilities，避免写死技能短语；排序后截断，保证菜单稳定且不拖慢 body。
        (sessionStore.capabilityList?.skills ?? [])
            .filter(\.enabled)
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func addSkillAttachment(_ skill: SkillCapability) {
        composerState.addAttachment(.skill(name: skill.name, path: skill.path))
        clearVoiceTransientStatus()
        showsAddContentPanel = false
    }

    private func setSendMode(_ mode: ComposerSendMode) {
        // 发送模式是“下一次发送”的轻量开关：视图层用现有 toggle API 对齐目标状态，
        // 避免为这次收纳改动扩展 ComposerState 的公共面。
        switch mode {
        case .standard:
            if composerState.isGoalModeSelected {
                composerState.toggleGoalMode()
            } else if composerState.isPlanModeSelected {
                composerState.togglePlanMode()
            }
        case .goal:
            if !composerState.isGoalModeSelected {
                composerState.toggleGoalMode()
            }
        case .plan:
            if !composerState.isPlanModeSelected {
                composerState.togglePlanMode()
            }
        }
    }

    private var goalButton: some View {
        let selected = composerState.isGoalModeSelected
        return composerModeButton(
            title: "目标",
            systemImage: "target",
            selected: selected,
            accessibilityLabel: "目标任务模式",
            showsTitle: composerModeButtonShowsTitle,
            action: {
                setSendMode(selected ? .standard : .goal)
            }
        )
        .keyboardShortcut("g", modifiers: [.command, .shift])
        .help(selected ? "关闭目标任务发送模式" : "将下一次发送设为目标任务")
    }

    private var planButton: some View {
        let selected = composerState.isPlanModeSelected
        return composerModeButton(
            title: "计划",
            systemImage: "list.clipboard",
            selected: selected,
            accessibilityLabel: "计划模式",
            showsTitle: composerModeButtonShowsTitle,
            action: {
                setSendMode(selected ? .standard : .plan)
            }
        )
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .help(selected ? "关闭计划模式" : "将下一次发送设为 Codex 计划模式")
    }

    private var composerModeButtonShowsTitle: Bool {
        !isCompactComposer
    }

    @ViewBuilder
    private func composerModeButton(
        title: String,
        systemImage: String,
        selected: Bool,
        accessibilityLabel: String,
        showsTitle: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        if selected {
            Button(action: action) {
                composerModeButtonLabel(title: title, systemImage: systemImage, showsTitle: showsTitle)
            }
            .buttonStyle(.borderedProminent)
            .tint(tokens.accent)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue("已选择")
            .accessibilityHint("只切换发送模式，不会立即发送")
        } else {
            Button(action: action) {
                composerModeButtonLabel(title: title, systemImage: systemImage, showsTitle: showsTitle)
                    .foregroundStyle(tokens.accent)
            }
            .buttonStyle(.bordered)
            .tint(tokens.accent)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue("未选择")
            .accessibilityHint("只切换发送模式，不会立即发送")
        }
    }

    @ViewBuilder
    private func composerModeButtonLabel(title: String, systemImage: String, showsTitle: Bool) -> some View {
        if showsTitle {
            Label(title, systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 14, weight: .semibold))
                .frame(width: 22, height: 22)
        }
    }

    @ViewBuilder
    private func followUpDeliverySendMenu(showLabels: Bool) -> some View {
        if canChooseRunningFollowUpDelivery {
            let tokens = themeStore.tokens(for: colorScheme)
            let isGuidedAvailable = canUseGuidedFollowUp
            let isGuidedSelected = guidedFollowUpEnabled && isGuidedAvailable
            Menu {
                Button {
                    guidedFollowUpEnabled = false
                } label: {
                    Label("排队下一轮", systemImage: isGuidedSelected ? "clock" : "checkmark")
                }
                Button {
                    if isGuidedAvailable {
                        guidedFollowUpEnabled = true
                    }
                } label: {
                    Label(isGuidedAvailable ? "引导当前回复" : "引导当前回复（等待回合）", systemImage: isGuidedSelected ? "checkmark" : "text.bubble")
                }
                .disabled(!isGuidedAvailable)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isGuidedSelected ? "text.bubble.fill" : "clock")
                        .font(themeStore.uiFont(size: 16, weight: .bold))
                    if showLabels {
                        Text(isGuidedSelected ? "引导" : "排队")
                            .font(themeStore.uiFont(.callout, weight: .semibold))
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.up")
                        .font(themeStore.uiFont(size: 10, weight: .bold))
                        .opacity(0.72)
                }
                .foregroundStyle(isGuidedSelected ? tokens.accent : tokens.secondaryText)
                .frame(height: 44)
                .padding(.horizontal, showLabels ? 12 : 8)
                .frame(minWidth: showLabels ? 76 : 48)
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
            .buttonStyle(.plain)
            .help(isGuidedSelected ? "运行中发送会直接引导当前回复" : "运行中发送会排队为下一轮消息")
            .accessibilityLabel("运行中追加方式")
            .accessibilityValue(isGuidedSelected ? "引导当前回复" : "排队下一轮")
        }
    }

    @ViewBuilder
    private var voiceReviewNotice: some View {
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

    private var selectedVoiceLanguage: VoiceInputLanguage {
        VoiceInputLanguage.stored(selectedVoiceLanguageID)
    }

    private var voiceLanguageMenu: some View {
        Menu {
            ForEach(VoiceInputLanguage.allCases) { language in
                Button {
                    selectedVoiceLanguageID = language.rawValue
                } label: {
                    Label(language.title, systemImage: selectedVoiceLanguage == language ? "checkmark" : "globe")
                }
            }
        } label: {
            Label(selectedVoiceLanguage.title, systemImage: "globe")
                .foregroundStyle(themeStore.tokens(for: colorScheme).accent)
        }
        .buttonStyle(.bordered)
        .tint(themeStore.tokens(for: colorScheme).accent)
    }

    private var runSettingsMenu: some View {
        Menu {
            modelOptionsMenu
            reasoningOptionsMenu
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
            Label("运行", systemImage: "gearshape")
                .foregroundStyle(themeStore.tokens(for: colorScheme).accent)
        }
        .buttonStyle(.bordered)
        .tint(themeStore.tokens(for: colorScheme).accent)
    }

    private var modelOptionsMenu: some View {
        Menu {
            Button("默认") {
                composerState.turnOptions.runtimeProvider = payloadRuntimeProviderForSelectedSessionLock()
                composerState.turnOptions.model = nil
                composerState.turnOptions.modelProvider = nil
            }
            ForEach(modelOptionsForMenu) { option in
                Button(option.menuTitle) {
                    composerState.turnOptions.runtimeProvider = option.runtimeProvider
                    composerState.turnOptions.model = option.model
                    composerState.turnOptions.modelProvider = option.provider
                }
            }
            Divider()
            Button {
                Task { await sessionStore.refreshAppServerModelOptions(force: true) }
            } label: {
                Label(sessionStore.isRefreshingAppServerModels ? "刷新中" : "刷新模型列表", systemImage: "arrow.clockwise")
            }
            .disabled(sessionStore.isRefreshingAppServerModels)
        } label: {
            Label(composerState.turnOptions.model ?? "默认模型", systemImage: "cpu")
        }
    }

    private var reasoningOptionsMenu: some View {
        Menu {
            Button("默认") { composerState.turnOptions.reasoningEffort = nil }
            ForEach(CodexAppServerReasoningEffort.allCases) { effort in
                Button(effort.rawValue) { composerState.turnOptions.reasoningEffort = effort }
            }
        } label: {
            Label(composerState.turnOptions.reasoningEffort?.rawValue ?? "推理默认", systemImage: "brain.head.profile")
        }
    }

    private var serviceTierOptionsMenu: some View {
        Menu {
            Button("默认") { composerState.turnOptions.serviceTier = nil }
            Button("auto") { composerState.turnOptions.serviceTier = "auto" }
            Button("priority") { composerState.turnOptions.serviceTier = "priority" }
            Button("flex") { composerState.turnOptions.serviceTier = "flex" }
        } label: {
            Label(composerState.turnOptions.serviceTier ?? "速度默认", systemImage: "speedometer")
        }
    }

    private var outputOptionsMenu: some View {
        Menu {
            Section("摘要") {
                Button("默认") { composerState.turnOptions.reasoningSummary = nil }
                ForEach(CodexAppServerReasoningSummary.allCases) { summary in
                    Button(summary.rawValue) { composerState.turnOptions.reasoningSummary = summary }
                }
            }
            Section("人格") {
                Button("默认") { composerState.turnOptions.personality = nil }
                Button("none") { composerState.turnOptions.personality = CodexAppServerPersonality.none }
                Button("friendly") { composerState.turnOptions.personality = .friendly }
                Button("pragmatic") { composerState.turnOptions.personality = .pragmatic }
            }
        } label: {
            Label("摘要/人格", systemImage: "text.bubble")
        }
    }

    private var permissionMenu: some View {
        Menu {
            Section("权限模式") {
                ForEach(ComposerPermissionMode.allCases) { mode in
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
            Label(composerState.permissionMode.title, systemImage: composerState.permissionMode.systemImage)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("权限模式")
        .accessibilityValue(permissionTitle)
    }

    // 录音/准备/转写的实时状态，作为状态行中段的胶囊。波形单独订阅 levelMeter，
    // 不会带动整条 ComposerView 重绘。紧凑布局（iPhone/窄分屏）下只留波形、隐去文案，避免一行挤不下。
    @ViewBuilder
    private var voiceWaveformContent: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        if isVoiceTranscribing {
            voiceActivityCapsule(tint: tokens.accent) {
                ProgressView()
                    .controlSize(.small)
                    .tint(tokens.accent)
                if !isCompactComposer {
                    Text("模型转写中 · \(selectedVoiceLanguage.title)")
                        .lineLimit(1)
                }
            }
        } else if voiceInput.isRecording {
            voiceActivityCapsule(tint: tokens.voiceRecording, emphasized: true) {
                VoiceWaveformView(meter: voiceInput.levelMeter, isActive: true, colors: tokens.voiceWaveformGradient)
                    .frame(width: isCompactComposer ? 124 : 190, height: isCompactComposer ? 32 : 34)
                if !isCompactComposer {
                    Text("正在听，松手转写 · \(selectedVoiceLanguage.title)")
                        .lineLimit(1)
                }
            }
        } else if voiceInput.isPreparing || isVoicePressActive {
            voiceActivityCapsule(tint: tokens.accent) {
                ProgressView()
                    .controlSize(.small)
                    .tint(tokens.accent)
                if !isCompactComposer {
                    Text("正在准备…")
                        .lineLimit(1)
                }
            }
        }
    }

    private func voiceActivityCapsule<Content: View>(
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

    private var modelOptionsForMenu: [CodexAppServerModelOption] {
        let options = sessionStore.appServerModelOptions.isEmpty ? CodexAppServerModelOption.builtInFallback : sessionStore.appServerModelOptions
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

    private func applyDefaultPermissionMode() {
        composerState.applyPermissionMode(ComposerPermissionMode.stored(defaultPermissionModeID))
    }

    private func setPermissionMode(_ mode: ComposerPermissionMode) {
        defaultPermissionModeID = mode.rawValue
        composerState.applyPermissionMode(mode)
    }

    private var turnOptionChipItems: [ComposerChipItem] {
        var items: [ComposerChipItem] = []
        if composerState.isGoalModeSelected {
            items.append(ComposerChipItem(id: "send-goal", text: "目标任务", symbol: "target", tint: themeStore.tokens(for: colorScheme).accent))
        }
        if composerState.isPlanModeSelected {
            items.append(ComposerChipItem(id: "send-plan", text: "计划模式", symbol: "list.clipboard", tint: themeStore.tokens(for: colorScheme).accent))
        }
        items.append(ComposerChipItem(id: "model", text: selectedModelSummaryTitle, symbol: "cpu", tint: themeStore.tokens(for: colorScheme).accent))
        items.append(
            ComposerChipItem(
                id: "permission",
                text: composerState.permissionMode.chipTitle,
                symbol: composerState.permissionMode.systemImage,
                tint: permissionTint
            )
        )

        if let effort = composerState.turnOptions.reasoningEffort {
            items.append(ComposerChipItem(id: "effort", text: "推理 \(effort.rawValue)", symbol: "brain.head.profile", tint: .secondary))
        }
        if let tier = composerState.turnOptions.serviceTier?.trimmingCharacters(in: .whitespacesAndNewlines), !tier.isEmpty {
            items.append(ComposerChipItem(id: "tier", text: "速度 \(tier)", symbol: "speedometer", tint: .secondary))
        }
        if selectedVoiceLanguage != .automatic {
            items.append(ComposerChipItem(id: "voice-language", text: "语音 \(selectedVoiceLanguage.title)", symbol: "globe", tint: .secondary))
        }
        if let summary = composerState.turnOptions.reasoningSummary {
            items.append(ComposerChipItem(id: "summary", text: "摘要 \(summary.rawValue)", symbol: "text.bubble", tint: .secondary))
        }
        if let personality = composerState.turnOptions.personality {
            items.append(ComposerChipItem(id: "personality", text: "人格 \(personality.rawValue)", symbol: "person.crop.circle", tint: .secondary))
        }
        if developerModeEnabled, hasAdvancedTurnOptions {
            items.append(ComposerChipItem(id: "advanced", text: "高级已应用", symbol: "ellipsis.circle", tint: .orange))
        }
        return items
    }

    private var selectedModelSummaryTitle: String {
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

    private var defaultModelSummaryTitle: String {
        guard let option = modelOptionsForMenu.first(where: \.isDefault) ?? modelOptionsForMenu.first else {
            return "默认模型"
        }
        return developerModeEnabled ? option.menuTitle : option.title
    }

    private var hasAdvancedTurnOptions: Bool {
        hasCustomRuntimeProvider ||
            composerState.turnOptions.config != nil ||
            composerState.turnOptions.baseInstructions != nil ||
            composerState.turnOptions.developerInstructions != nil ||
            composerState.turnOptions.outputSchema != nil ||
            composerState.turnOptions.serviceName != nil ||
            composerState.turnOptions.sessionStartSource != nil ||
            composerState.turnOptions.threadSource != nil
    }

    private var hasCustomRuntimeProvider: Bool {
        guard let runtime = composerState.turnOptions.runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !runtime.isEmpty else {
            return false
        }
        return runtime != "codex" && runtime != "claude"
    }

    private var selectedSessionRuntimeProviderForModelMenu: String? {
        guard let session = sessionStore.selectedSession else {
            return nil
        }
        if session.source == "local", session.runtimeProvider == nil {
            return nil
        }
        return normalizedRuntimeProvider(session.runtimeProvider ?? session.source)
    }

    private func clampModelSelectionToSelectedSessionRuntime() {
        guard let runtimeProvider = selectedSessionRuntimeProviderForModelMenu else {
            return
        }
        guard normalizedRuntimeProvider(composerState.turnOptions.runtimeProvider) != runtimeProvider else {
            return
        }
        composerState.turnOptions.runtimeProvider = payloadRuntimeProviderForSelectedSessionLock()
        composerState.turnOptions.model = nil
        composerState.turnOptions.modelProvider = nil
    }

    private func payloadRuntimeProviderForSelectedSessionLock() -> String? {
        guard let runtimeProvider = selectedSessionRuntimeProviderForModelMenu else {
            return nil
        }
        return runtimeProvider == "codex" ? nil : runtimeProvider
    }

    private func normalizedRuntimeProvider(_ rawValue: String?) -> String {
        CodexAppServerSessionRuntime.normalizedRuntimeProvider(rawValue)
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        if !composerState.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(composerState.attachments.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 6) {
                            Button {
                                previewingAttachment = item
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: attachmentSymbol(for: item))
                                    Text(item.previewText)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!canPreviewAttachment(item))

                            Button {
                                composerState.removeAttachment(at: index)
                                if previewingAttachment?.id == item.id {
                                    previewingAttachment = nil
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .accessibilityLabel("移除")
                            }
                            .buttonStyle(.plain)
                        }
                        .font(themeStore.uiFont(.caption))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(themeStore.tokens(for: colorScheme).elevatedSurface, in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(themeStore.tokens(for: colorScheme).border)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var attachmentErrorNotice: some View {
        if let attachmentErrorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text(attachmentErrorMessage)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .font(themeStore.uiFont(.caption))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var voiceErrorMessage: some View {
        if let errorMessage = voiceInput.errorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text(errorMessage)
                    .lineLimit(2)
                    .layoutPriority(1)
                    .foregroundStyle(.red)
                Spacer(minLength: 0)
                if retryableVoiceTranscription != nil {
                    Button {
                        retryVoiceTranscription()
                    } label: {
                        if isVoiceTranscribing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("重试转写", systemImage: "arrow.clockwise")
                        }
                    }
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isVoiceTranscribing)
                    .accessibilityLabel("重试语音转写")
                    .help("重新提交刚才的录音")
                }
                Button {
                    clearVoiceTransientStatus()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.medium)
                        .foregroundStyle(.red.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭语音转写错误提示")
                .help("关闭提示")
            }
            .font(themeStore.uiFont(.caption))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var voiceNoticeMessage: some View {
        if let noticeMessage = voiceInput.noticeMessage {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                Text(noticeMessage)
                    .lineLimit(2)
            }
            .font(themeStore.uiFont(.caption))
            .foregroundStyle(themeStore.tokens(for: colorScheme).accent)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var runtimeChipItems: [(text: String, symbol: String, tint: Color)] {
        guard let session = sessionStore.selectedSession else {
            return []
        }
        var items: [(text: String, symbol: String, tint: Color)] = []
        if session.activeTurnID != nil {
            items.append(("回合处理中", "bolt.fill", themeStore.tokens(for: colorScheme).success))
        }
        if let lastSeq = session.lastSeq {
            items.append(("seq \(lastSeq)", "number", .secondary))
        }
        if let usage = session.usage?.compactText {
            items.append((usage, "gauge.with.dots.needle.33percent", .secondary))
        }
        return items
    }

    @ViewBuilder
    private var pendingApprovalAction: some View {
        if !sessionStore.isSelectedSessionObserving, let approval = sessionStore.selectedSession?.pendingApproval {
            PendingApprovalActionCard(
                approval: approval,
                isSendingDecision: sessionStore.isApprovalDecisionPending(approval),
                onApprove: { sessionStore.decideApproval(approval, accept: true) },
                onDecline: { sessionStore.decideApproval(approval, accept: false) }
            )
        }
    }

    @ViewBuilder
    private var pendingUserInputAction: some View {
        if !sessionStore.isSelectedSessionObserving, let request = sessionStore.selectedSession?.pendingUserInput {
            PendingUserInputActionCard(
                request: request,
                isSubmitting: sessionStore.isUserInputResponsePending(request),
                onSubmit: { answers in
                    sessionStore.respondToUserInput(request, answers: answers)
                }
            )
        }
    }

    private func sendButton(showLabels: Bool) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let isGoalMode = composerState.isGoalModeSelected
        let isPlanMode = composerState.isPlanModeSelected
        let isGuidedFollowUp = !isGoalMode && !isPlanMode && canUseGuidedFollowUp && guidedFollowUpEnabled
        let title: String
        if composerState.voiceDraftNeedsReview {
            title = isGoalMode ? "确认目标" : isPlanMode ? "确认计划" : isGuidedFollowUp ? "确认引导" : "确认发送"
        } else {
            title = isGoalMode ? "发送目标" : isPlanMode ? "生成计划" : isGuidedFollowUp ? "引导" : "发送"
        }
        let symbol = composerState.voiceDraftNeedsReview ? "checkmark.circle.fill" : (isGoalMode ? "target" : isPlanMode ? "list.clipboard" : isGuidedFollowUp ? "text.bubble.fill" : "paperplane.fill")
        let enabled = canSubmitDraft

        // 自绘成与“按住说话”同高同圆角的实心主按钮，让语音/发送成为右侧一组协调的主操作，
        // 而不是一个系统 prominent 小按钮配一个自定义大胶囊那种割裂感。
        return Button {
            submitDraft()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(themeStore.uiFont(size: 17, weight: .bold))
                if showLabels {
                    Text(title)
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(enabled ? Color.white : tokens.tertiaryText)
            .frame(height: 44)
            .padding(.horizontal, showLabels ? 18 : 0)
            .frame(minWidth: 44)
            .background(
                enabled ? tokens.accent : tokens.elevatedSurface,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                if !enabled {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(tokens.border)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!enabled)
        .accessibilityLabel(isGoalMode ? "发送目标任务" : (composerState.voiceDraftNeedsReview ? "确认发送语音草稿" : "发送"))
    }

    private var permissionTitle: String {
        "\(composerState.permissionMode.title) · \(composerState.turnOptions.sandboxMode.title)"
    }

    private var permissionWireSummary: String {
        "\(composerState.turnOptions.approvalPolicy.rawValue) · \(composerState.turnOptions.approvalsReviewer)"
    }

    private var permissionTint: Color {
        switch composerState.permissionMode {
        case .requestApproval:
            return themeStore.tokens(for: colorScheme).accent
        case .readOnly:
            return .secondary
        case .autoApprove:
            return themeStore.tokens(for: colorScheme).success
        case .fullAccess:
            return .red
        }
    }

    private var composerMinHeight: CGFloat {
        if usesCollapsedComposerTextHeight {
            return isCompactComposer ? 38 : 34
        }
        if composerState.hasNonWhitespaceDraft {
            // 单行文字输入不要被强行撑成大文本框；内容增多时高度仍由 UIKit 测量值继续向上扩展。
            return isCompactComposer ? 44 : 48
        }
        if !composerState.attachments.isEmpty || composerState.voiceDraftNeedsReview {
            return isCompactComposer ? 52 : 56
        }
        if isCompactComposer {
            return 60
        }
        return 72
    }

    private var composerMaxHeight: CGFloat {
        if isCompactComposer {
            return 190
        }
        return 260
    }

    private var composerTextHeight: CGFloat {
        if usesCollapsedComposerTextHeight {
            return composerMinHeight
        }
        let measured = measuredComposerTextHeight > 0 ? measuredComposerTextHeight : composerMinHeight
        return min(max(measured, composerMinHeight), composerMaxHeight)
    }

    private var usesCollapsedComposerTextHeight: Bool {
        // 空输入时先保持轻量高度；一旦有文字/附件/语音草稿，才恢复更像命令面板的多行空间。
        composerState.isEmpty && !composerState.voiceDraftNeedsReview
    }

    private var composerInputRowSpacing: CGFloat {
        (availableWidth ?? 920) < 360 ? 6 : 8
    }

    private var voiceActionColumnWidth: CGFloat {
        voiceButtonWidth
    }

    private var voiceButtonWidth: CGFloat {
        let width = availableWidth ?? 920
        if width < 360 {
            return 60
        }
        if isCompactComposer {
            return 68
        }
        return 104
    }

    private var voiceButtonHeight: CGFloat {
        let measuredHeight = measuredComposerCardHeight > 0 ? measuredComposerCardHeight : estimatedComposerCardHeight
        return max(voiceButtonMinimumHeight, measuredHeight)
    }

    private var voiceButtonShowsTitle: Bool {
        voiceButtonWidth >= 96 && !isCompactComposer
    }

    private var estimatedComposerCardHeight: CGFloat {
        let toolbarHeight: CGFloat = 46
        let reviewHeight = composerState.voiceDraftNeedsReview ? 28 + composerCardSpacing : 0
        // 首次布局还没有 GeometryReader 回传高度时，用同一套尺寸预估，避免右侧语音按钮首帧跳动。
        return composerTextHeight + toolbarHeight + reviewHeight + composerCardPadding * 2 + composerCardSpacing
    }

    private var voiceButtonMinimumHeight: CGFloat {
        isCompactComposer ? 78 : 90
    }

    private var composerCardPadding: CGFloat {
        usesCollapsedComposerTextHeight ? 10 : 12
    }

    private var composerCardSpacing: CGFloat {
        usesCollapsedComposerTextHeight ? 8 : 12
    }

    private var composerUIFont: UIFont {
        let size = themeStore.scaledFontSize(17)
        let base = UIFont.systemFont(ofSize: size)
        let design: UIFontDescriptor.SystemDesign
        switch themeStore.uiFontPreset {
        case .system:
            design = .default
        case .rounded:
            design = .rounded
        case .serif:
            design = .serif
        }
        guard let descriptor = base.fontDescriptor.withDesign(design) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    private func composerActivity(_ activity: SessionForegroundActivity) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return HStack(spacing: 7) {
            if activity.showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(tokens.success)
            } else {
                Circle()
                    .fill(tokens.success)
                    .frame(width: 7, height: 7)
            }
            Text(activity.title)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(themeStore.uiFont(.caption, weight: .medium))
        .foregroundStyle(tokens.secondaryText)
    }

    private func openManualInput(_ kind: ManualInputKind) {
        manualInputKind = kind
        showsAddContentPanel = false
        showsManualInputSheet = true
    }

    private func beginHoldToTalk() {
        guard !isVoicePressActive &&
            !voiceInput.isPreparing &&
            !voiceInput.isRecording &&
            !isVoiceTranscribing &&
            voiceTranscriptionTask == nil
        else {
            return
        }
        clearVoiceTransientStatus()
        isVoicePressActive = true
        voicePressStartedAt = Date()
        composerState.beginVoiceInput()
        let language = selectedVoiceLanguage
        let context = VoiceTranscriptionContext(sessionID: sessionStore.selectedSessionID)
        activeVoiceTranscriptionContext = context
        voiceInput.start { recording in
            isVoicePressActive = false
            voicePressStartedAt = nil
            guard let recording else {
                if activeVoiceTranscriptionContext == context {
                    activeVoiceTranscriptionContext = nil
                }
                composerState.endVoiceInput()
                return
            }
            guard isVoiceTranscriptionContextCurrent(context) else {
                try? FileManager.default.removeItem(at: recording.fileURL)
                composerState.endVoiceInput()
                return
            }
            voiceTranscriptionTask = Task {
                await transcribeVoiceRecording(recording, language: language, context: context)
            }
        }
    }

    private func endHoldToTalk() {
        guard isVoicePressActive || voiceInput.isPreparing || voiceInput.isRecording else {
            return
        }
        let pressDuration = voicePressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let releasedBeforeRecording = voiceInput.isPreparing && !voiceInput.isRecording
        isVoicePressActive = false
        voicePressStartedAt = nil
        if pressDuration < Self.minimumVoicePressDuration {
            // 很短的点按大多是误触，直接取消录音，不再发起一次必失败的转写请求。
            voiceInput.cancel()
            activeVoiceTranscriptionContext = nil
            composerState.endVoiceInput()
            voiceInput.setNoticeMessage("按住说话，松手转写")
            return
        }
        voiceInput.stop()
        if releasedBeforeRecording {
            voiceInput.setErrorMessage("麦克风还没准备好，请按住到出现“正在听”后再说")
        }
    }

    private func toggleVoiceInputFromKeyboard() {
        guard !isVoiceTranscribing else {
            return
        }
        if isVoicePressActive || voiceInput.isRecording {
            endHoldToTalk()
        } else {
            beginHoldToTalk()
        }
    }

    @MainActor
    private func clearVoiceTransientStatus() {
        retryableVoiceTranscription = nil
        voiceInput.setErrorMessage(nil)
        voiceInput.setNoticeMessage(nil)
    }

    @MainActor
    private func cancelVoiceInteraction(clearStatus: Bool) {
        // 切会话、离开页面或发送草稿时取消当前录音/转写；旧请求即使晚返回，也不能写入新会话的输入框。
        voiceTranscriptionTask?.cancel()
        voiceTranscriptionTask = nil
        activeVoiceTranscriptionContext = nil
        voicePressStartedAt = nil
        if isVoicePressActive || voiceInput.isPreparing || voiceInput.isRecording {
            voiceInput.cancel()
        }
        isVoicePressActive = false
        isVoiceTranscribing = false
        composerState.endVoiceInput()
        if clearStatus {
            clearVoiceTransientStatus()
        }
    }

    private func isVoiceTranscriptionContextCurrent(_ context: VoiceTranscriptionContext) -> Bool {
        activeVoiceTranscriptionContext == context && sessionStore.selectedSessionID == context.sessionID
    }

    @MainActor
    private func autoDismissVoiceErrorIfNeeded(_ message: String?) async {
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let delay = voiceErrorAutoDismissDelaySeconds(for: message)
        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
        guard !Task.isCancelled,
              voiceInput.errorMessage == message,
              !isVoiceTranscribing else {
            return
        }
        clearVoiceTransientStatus()
    }

    private func voiceErrorAutoDismissDelaySeconds(for message: String) -> UInt64 {
        if let retryAfter = Self.retryAfterSeconds(from: message) {
            // 429/临时不可用会给出 retry-after；提示至少保留到可重试窗口之后，
            // 但也设上限，避免底部红条永久占位。
            return UInt64(min(max(retryAfter + 5, 12), 45))
        }
        return 12
    }

    @MainActor
    private func transcribeVoiceRecording(
        _ recording: VoiceRecordingResult,
        language: VoiceInputLanguage,
        context: VoiceTranscriptionContext
    ) async {
        guard isVoiceTranscriptionContextCurrent(context) else {
            try? FileManager.default.removeItem(at: recording.fileURL)
            return
        }
        isVoiceTranscribing = true
        retryableVoiceTranscription = nil
        voiceInput.setErrorMessage(nil)
        var retryCandidate: RetryableVoiceTranscription?
        defer {
            if isVoiceTranscriptionContextCurrent(context) {
                isVoiceTranscribing = false
                activeVoiceTranscriptionContext = nil
                voiceTranscriptionTask = nil
                composerState.endVoiceInput()
            }
            try? FileManager.default.removeItem(at: recording.fileURL)
        }
        do {
            async let dataTask = Self.voiceRecordingData(recording.fileURL)
            async let durationTask = Self.safeVoiceRecordingDuration(recording.fileURL)
            let data = try await dataTask
            let assetDuration = await durationTask
            try Task.checkCancellation()
            guard isVoiceTranscriptionContextCurrent(context) else {
                return
            }
            let usableDuration = max(recording.recordedDuration, assetDuration)
            if data.count < 1_024 || usableDuration < Self.minimumUsableVoiceDuration {
                voiceInput.setErrorMessage(shortVoiceRecordingMessage(recording: recording, usableDuration: usableDuration))
                return
            }
            retryCandidate = RetryableVoiceTranscription(
                filename: recording.fileURL.lastPathComponent,
                contentType: "audio/mp4",
                audioData: data,
                language: language,
                recordedDuration: usableDuration,
                pressDuration: recording.pressDuration,
                sessionID: context.sessionID
            )
            let response = try await sessionStore.transcribeVoice(
                filename: recording.fileURL.lastPathComponent,
                contentType: "audio/mp4",
                audioData: data,
                language: language.transcriptionLanguageCode,
                prompt: language.transcriptionPrompt
            )
            try Task.checkCancellation()
            guard isVoiceTranscriptionContextCurrent(context) else {
                return
            }
            composerState.applyVoiceTranscript(response.text)
            retryableVoiceTranscription = nil
        } catch is CancellationError {
            retryableVoiceTranscription = nil
        } catch {
            voiceInput.setErrorMessage(userFacingVoiceTranscriptionError(error, recording: recording))
            if let retryCandidate, Self.isRetryableVoiceTranscriptionError(error) {
                // 临时上游错误时保留这次录音的内存副本，用户点一次即可重发；
                // 成功、录音过短、权限错误等场景不保留，避免错误按钮误导用户。
                retryableVoiceTranscription = retryCandidate
            } else {
                retryableVoiceTranscription = nil
            }
        }
    }

    private func retryVoiceTranscription() {
        guard let retryableVoiceTranscription, !isVoiceTranscribing, voiceTranscriptionTask == nil else {
            return
        }
        guard retryableVoiceTranscription.sessionID == sessionStore.selectedSessionID else {
            self.retryableVoiceTranscription = nil
            voiceInput.setErrorMessage("会话已切换，请重新录音")
            return
        }
        let context = VoiceTranscriptionContext(sessionID: retryableVoiceTranscription.sessionID)
        activeVoiceTranscriptionContext = context
        voiceTranscriptionTask = Task {
            await transcribeCachedVoiceRecording(retryableVoiceTranscription, context: context)
        }
    }

    @MainActor
    private func transcribeCachedVoiceRecording(_ cached: RetryableVoiceTranscription, context: VoiceTranscriptionContext) async {
        guard isVoiceTranscriptionContextCurrent(context) else {
            return
        }
        isVoiceTranscribing = true
        composerState.beginVoiceInput()
        voiceInput.setErrorMessage(nil)
        defer {
            if isVoiceTranscriptionContextCurrent(context) {
                isVoiceTranscribing = false
                activeVoiceTranscriptionContext = nil
                voiceTranscriptionTask = nil
                composerState.endVoiceInput()
            }
        }
        do {
            let response = try await sessionStore.transcribeVoice(
                filename: cached.filename,
                contentType: cached.contentType,
                audioData: cached.audioData,
                language: cached.language.transcriptionLanguageCode,
                prompt: cached.language.transcriptionPrompt
            )
            try Task.checkCancellation()
            guard isVoiceTranscriptionContextCurrent(context) else {
                return
            }
            composerState.applyVoiceTranscript(response.text)
            if retryableVoiceTranscription?.id == cached.id {
                retryableVoiceTranscription = nil
            }
            voiceInput.setNoticeMessage("语音已重新转写，请确认草稿后发送")
        } catch is CancellationError {
            if retryableVoiceTranscription?.id == cached.id {
                retryableVoiceTranscription = nil
            }
        } catch {
            voiceInput.setErrorMessage(userFacingVoiceTranscriptionError(error))
            if Self.isRetryableVoiceTranscriptionError(error) {
                retryableVoiceTranscription = cached
            } else if retryableVoiceTranscription?.id == cached.id {
                retryableVoiceTranscription = nil
            }
        }
    }

    nonisolated private static func voiceRecordingData(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
    }

    nonisolated private static func safeVoiceRecordingDuration(_ url: URL) async -> TimeInterval {
        (try? await voiceRecordingDuration(url)) ?? 0
    }

    private func shortVoiceRecordingMessage(recording: VoiceRecordingResult, usableDuration: TimeInterval) -> String {
        // 区分“用户真的很快松手”和“按住了但录音器实际采样很短”，避免把启动延迟误报成没按够 1 秒。
        if recording.pressDuration >= 0.9 && usableDuration < Self.minimumUsableVoiceDuration {
            return "麦克风启动较慢，刚才录到的声音太短，请等“正在听”后再说"
        }
        return "按得有点短，请按住说完整句再松开"
    }

    nonisolated private static func voiceRecordingDuration(_ url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private func userFacingVoiceTranscriptionError(_ error: Error, recording: VoiceRecordingResult? = nil) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return "语音转写失败，请稍后重试"
        }
        if message.localizedCaseInsensitiveContains("API Key") {
            return message
        }
        if message.contains("没有识别到语音内容") || message.contains("按住说话至少 1 秒") {
            if let recording, recording.pressDuration >= 0.9 {
                return "没有识别到清晰语音，请靠近麦克风并说完整句后再松手"
            }
            return "没有识别到清晰语音，请按住说完整句后再松手"
        }
        if Self.isTemporaryUnavailableVoiceErrorMessage(message) {
            if let seconds = Self.retryAfterSeconds(from: message) {
                return "语音转写暂不可用，请 \(seconds) 秒后重试"
            }
            return "语音转写暂不可用，请稍后重试"
        }
        if Self.isTimeoutVoiceErrorMessage(message) {
            return "语音转写请求超时，请稍后重试"
        }
        return "语音转写失败：\(message)"
    }

    nonisolated private static func isRetryableVoiceTranscriptionError(_ error: Error) -> Bool {
        if let apiError = error as? AgentAPIError,
           case AgentAPIError.server(let status, let message) = apiError {
            if isNonRetryableVoiceErrorMessage(message) {
                return false
            }
            if status == 408 || status == 429 {
                return true
            }
            if status == 500 || status == 502 || status == 503 || status == 504 {
                return true
            }
            return isTemporaryUnavailableVoiceErrorMessage(message) || isTimeoutVoiceErrorMessage(message)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed:
                return true
            default:
                break
            }
        }
        let message = error.localizedDescription
        if isNonRetryableVoiceErrorMessage(message) {
            return false
        }
        return isTemporaryUnavailableVoiceErrorMessage(message) || isTimeoutVoiceErrorMessage(message)
    }

    nonisolated private static func isNonRetryableVoiceErrorMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("api key")
            || lower.contains("codex login")
            || message.contains("登录态已失效")
            || message.contains("麦克风权限")
            || message.contains("没有识别到语音内容")
            || message.contains("按住说话至少")
    }

    nonisolated private static func isTemporaryUnavailableVoiceErrorMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("http 429")
            || lower.contains("429")
            || lower.contains("temporarily unavailable")
            || lower.contains("retry_after")
            || lower.contains("rate limit")
            || lower.contains("try again")
            || message.contains("暂不可用")
            || message.contains("稍后重试")
    }

    nonisolated private static func isTimeoutVoiceErrorMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("timed out")
            || lower.contains("timeout")
            || message.contains("超时")
    }

    nonisolated private static func retryAfterSeconds(from message: String) -> Int? {
        let patterns = [
            #""retry_after_seconds"\s*:\s*(\d+)"#,
            #"请\s*(\d+)\s*秒后重试"#
        ]
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            guard let match = regex.firstMatch(in: message, range: range),
                  let secondsRange = Range(match.range(at: 1), in: message),
                  let seconds = Int(message[secondsRange]) else {
                continue
            }
            return seconds
        }
        return nil
    }

    private func loadPhotoAttachment(_ item: PhotosPickerItem) {
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    return
                }
                let url = await Task.detached(priority: .userInitiated) {
                    let encoded = Self.compressedImageData(from: data) ?? data
                    return "data:image/jpeg;base64,\(encoded.base64EncodedString())"
                }.value
                await MainActor.run {
                    attachmentErrorMessage = nil
                    composerState.addAttachment(.image(url: url, detail: .auto))
                    selectedPhotoItem = nil
                }
            } catch {
                await MainActor.run {
                    attachmentErrorMessage = userFacingAttachmentError(error)
                    selectedPhotoItem = nil
                }
            }
        }
    }

    private func loadImageFileAttachment(_ url: URL) {
        Task {
            do {
                let data = try Self.readSecurityScopedFile(url)
                let inlineURL = await Task.detached(priority: .userInitiated) {
                    let encoded = Self.compressedImageData(from: data) ?? data
                    return "data:image/jpeg;base64,\(encoded.base64EncodedString())"
                }.value
                await MainActor.run {
                    attachmentErrorMessage = nil
                    composerState.addAttachment(.image(url: inlineURL, detail: .auto))
                }
            } catch {
                await MainActor.run {
                    attachmentErrorMessage = userFacingAttachmentError(error)
                }
            }
        }
    }

    nonisolated private static func readSecurityScopedFile(_ url: URL) throws -> Data {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try Data(contentsOf: url)
    }

    nonisolated private static func compressedImageData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else {
            return nil
        }
        let maxDimension: CGFloat = 1_280
        let largestSide = max(image.size.width, image.size.height)
        let scale = largestSide > maxDimension ? maxDimension / largestSide : 1
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        // 移动端只负责把截图/照片作为上下文传给 app-server；先降采样再 JPEG 编码，
        // 避免原图 base64 把 SwiftUI state、WebSocket payload 和内存峰值一起撑大。
        return resized.jpegData(compressionQuality: 0.82)
    }

    private func canPreviewAttachment(_ item: CodexAppServerUserInput) -> Bool {
        switch item {
        case .image, .localImage:
            return true
        case .text, .skill, .mention:
            return false
        }
    }

    private func userFacingAttachmentError(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "图片读取失败" : "图片读取失败：\(message)"
    }

    private func attachmentSymbol(for item: CodexAppServerUserInput) -> String {
        switch item {
        case .image, .localImage:
            return "photo"
        case .skill:
            return "wand.and.stars"
        case .mention:
            return "at"
        case .text:
            return "text.alignleft"
        }
    }
}

private struct ComposerStatusTray: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let sessionControlNotice: String?
    let quotaNotice: CodexQuotaNotice?
    let usage: CodexUsageDisplaySummary?
    let goal: ThreadGoal?
    let isGoalExpanded: Bool
    let isGoalUpdating: Bool
    let goalErrorMessage: String?
    let isRefreshDisabled: Bool
    let onTakeOver: () -> Void
    let onRefreshUsage: () -> Void
    let onEditGoal: () -> Void
    let onTogglePauseGoal: () -> Void
    let onCompleteGoal: () -> Void
    let onClearGoal: () -> Void
    let onToggleGoalExpanded: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let tint = trayTint(tokens: tokens)

        VStack(alignment: .leading, spacing: isGoalExpanded ? 8 : 0) {
            // 展开态把状态内容和收起按钮放到同一行，避免先出现一整行空白按钮区。
            if isGoalExpanded {
                expandedTrayContent(tokens: tokens)
            } else {
                collapsedHeader(tokens: tokens)
            }

            if let trimmedGoalError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(trimmedGoalError)
                        .lineLimit(2)
                }
                .font(themeStore.uiFont(.caption2, weight: .medium))
                .foregroundStyle(tokens.warning)
            }
        }
        .padding(isGoalExpanded ? 10 : 8)
        .frame(maxWidth: isGoalExpanded ? 680 : .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.28))
        }
        .accessibilityElement(children: .contain)
    }

    private func collapsedHeader(tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if sessionControlNotice != nil {
                        collapsedChip(title: "观察", systemImage: "eye", tint: tokens.secondaryText, tokens: tokens)
                    }
                    if quotaNotice != nil {
                        collapsedChip(title: "额度", systemImage: "speedometer", tint: tokens.warning, tokens: tokens)
                    } else if usage != nil {
                        collapsedChip(title: "额度", systemImage: "speedometer", tint: tokens.warning, tokens: tokens)
                    }
                    if let goal {
                        collapsedChip(title: collapsedGoalChipTitle(for: goal.status), systemImage: "target", tint: goalStatusTint(goal, tokens: tokens), tokens: tokens)
                    }
                }
                .padding(.vertical, 1)
            }
            .layoutPriority(1)

            iconButton(
                title: isGoalExpanded ? "收起状态" : "展开状态",
                systemImage: isGoalExpanded ? "chevron.up" : "chevron.down",
                tint: tokens.secondaryText,
                isDisabled: false,
                action: onToggleGoalExpanded
            )
        }
    }

    @ViewBuilder
    private func expandedTrayContent(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            expandedHeaderRow(tokens: tokens)
            if let goal {
                expandedGoalDetails(goal, tokens: tokens)
            }
        }
    }

    private func expandedHeaderRow(tokens: ThemeTokens) -> some View {
        HStack(alignment: .top, spacing: 8) {
            expandedHeaderSummary(tokens: tokens)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            iconButton(
                title: "收起状态",
                systemImage: "chevron.up",
                tint: tokens.secondaryText,
                isDisabled: false,
                action: onToggleGoalExpanded
            )
        }
    }

    @ViewBuilder
    private func expandedHeaderSummary(tokens: ThemeTokens) -> some View {
        if hasStatusModules {
            adaptiveStatusModules(tokens: tokens)
        } else if let goal {
            collapsedChip(
                title: collapsedGoalChipTitle(for: goal.status),
                systemImage: "target",
                tint: goalStatusTint(goal, tokens: tokens),
                tokens: tokens
            )
        }
    }

    private var hasStatusModules: Bool {
        sessionControlNotice != nil || quotaNotice != nil || usage != nil
    }

    private func collapsedChip(title: String, systemImage: String, tint: Color, tokens: ThemeTokens) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(tokens.surface.opacity(0.74), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(tint.opacity(0.18))
        }
        .accessibilityElement(children: .combine)
    }

    private func adaptiveStatusModules(tokens: ThemeTokens) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                statusModuleContent(tokens: tokens)
            }
            VStack(alignment: .leading, spacing: 6) {
                statusModuleContent(tokens: tokens)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statusModuleContent(tokens: ThemeTokens) -> some View {
        if let sessionControlNotice {
            observingSegment(sessionControlNotice, tokens: tokens)
        }
        if let quotaNotice {
            quotaSegment(quotaNotice, tokens: tokens)
        } else if let usage {
            usageSegment(usage, tokens: tokens)
        }
    }

    private func observingSegment(_ notice: String, tokens: ThemeTokens) -> some View {
        traySegment(tokens: tokens, tint: tokens.secondaryText, minWidth: 132) {
            HStack(spacing: 7) {
                segmentIcon("eye", tint: tokens.secondaryText)
                Text("仅观察")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                Button(action: onTakeOver) {
                    Text("接管")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.accent)
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(notice)
        }
    }

    private func quotaSegment(_ notice: CodexQuotaNotice, tokens: ThemeTokens) -> some View {
        traySegment(tokens: tokens, tint: tokens.warning, minWidth: 230, layoutPriority: 1) {
            HStack(spacing: 8) {
                segmentIcon("speedometer", tint: tokens.warning)
                Text(notice.blocksSending ? "额度已用尽" : notice.title)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.warning)
                    .lineLimit(1)
                Text(notice.message)
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                    .layoutPriority(1)
                refreshButton(tint: tokens.warning)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func usageSegment(_ usage: CodexUsageDisplaySummary, tokens: ThemeTokens) -> some View {
        traySegment(tokens: tokens, tint: tokens.warning, minWidth: 250, layoutPriority: 1) {
            HStack(spacing: 8) {
                segmentIcon("speedometer", tint: tokens.warning)
                Text("额度 \(usage.primaryText)")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.warning)
                    .lineLimit(1)
                Text(usage.secondaryText)
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                    .layoutPriority(1)
                refreshButton(tint: tokens.warning)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func expandedGoalDetails(_ goal: ThreadGoal, tokens: ThemeTokens) -> some View {
        let tint = goalStatusTint(goal, tokens: tokens)
        return VStack(alignment: .leading, spacing: 8) {
            Text(goal.objective)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(3)

            if let progress = goal.budgetProgressFraction {
                ProgressView(value: progress)
                    .tint(tint)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("目标 token 预算进度")
                    .accessibilityValue(goal.budgetPercentText ?? goal.progressText)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    goalMetrics(goal, tokens: tokens)
                    Spacer(minLength: 8)
                    goalActionRow(goal, tint: tint, tokens: tokens)
                }
                VStack(alignment: .leading, spacing: 8) {
                    goalMetrics(goal, tokens: tokens)
                    goalActionRow(goal, tint: tint, tokens: tokens)
                }
            }
        }
    }

    private func goalMetrics(_ goal: ThreadGoal, tokens: ThemeTokens) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                goalDetailText("状态 \(goal.status.displayText)", symbol: "circle.dashed", tokens: tokens)
                goalDetailText("进度 \(goal.progressText)", symbol: "gauge.with.dots.needle.33percent", tokens: tokens)
                if let percent = goal.budgetPercentText {
                    goalDetailText("预算 \(percent)", symbol: "percent", tokens: tokens)
                }
                goalDetailText("用时 \(goal.elapsedText)", symbol: "timer", tokens: tokens)
            }
            VStack(alignment: .leading, spacing: 4) {
                goalDetailText("状态 \(goal.status.displayText)", symbol: "circle.dashed", tokens: tokens)
                goalDetailText("进度 \(goal.progressText)", symbol: "gauge.with.dots.needle.33percent", tokens: tokens)
                if let percent = goal.budgetPercentText {
                    goalDetailText("预算 \(percent)", symbol: "percent", tokens: tokens)
                }
                goalDetailText("用时 \(goal.elapsedText)", symbol: "timer", tokens: tokens)
            }
        }
    }

    private func goalActionRow(_ goal: ThreadGoal, tint: Color, tokens: ThemeTokens) -> some View {
        HStack(spacing: 6) {
            iconButton(title: "编辑目标", systemImage: "pencil", tint: tokens.secondaryText, isDisabled: isGoalUpdating, action: onEditGoal)
            iconButton(title: primaryGoalActionTitle(for: goal.status), systemImage: primaryGoalActionSymbol(for: goal.status), tint: tint, isDisabled: isGoalUpdating, action: onTogglePauseGoal)
            iconButton(title: "标记完成", systemImage: "checkmark.circle", tint: tokens.success, isDisabled: isGoalUpdating || goal.status == .complete, action: onCompleteGoal)
            iconButton(title: "清除目标", systemImage: "trash", tint: .red, isDisabled: isGoalUpdating, action: onClearGoal)
        }
    }

    private func traySegment<Content: View>(
        tokens: ThemeTokens,
        tint: Color,
        minWidth: CGFloat? = nil,
        layoutPriority: Double = 0,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minWidth: minWidth, minHeight: 38)
            .background(tokens.surface.opacity(0.74), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tint.opacity(0.18))
            }
            .layoutPriority(layoutPriority)
    }

    private func segmentIcon(_ systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(themeStore.uiFont(.caption, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
            .background(tint.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }

    private func refreshButton(tint: Color) -> some View {
        Button(action: onRefreshUsage) {
            Image(systemName: "arrow.clockwise")
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isRefreshDisabled ? themeStore.tokens(for: colorScheme).tertiaryText : tint)
        .disabled(isRefreshDisabled)
        .help("刷新 Codex 使用量")
        .accessibilityLabel("刷新 Codex 使用量")
    }

    private func iconButton(
        title: String,
        systemImage: String,
        tint: Color,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(isDisabled ? themeStore.tokens(for: colorScheme).tertiaryText : tint)
                .frame(width: 30, height: 30)
                .background(themeStore.tokens(for: colorScheme).elevatedSurface.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(themeStore.tokens(for: colorScheme).border.opacity(0.72))
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(title)
        .accessibilityLabel(title)
    }

    private func goalDetailText(_ text: String, symbol: String, tokens: ThemeTokens) -> some View {
        Label(text, systemImage: symbol)
            .font(themeStore.uiFont(.caption2, weight: .medium))
            .foregroundStyle(tokens.secondaryText)
            .lineLimit(1)
    }

    private var trimmedGoalError: String? {
        let trimmed = goalErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func trayTint(tokens: ThemeTokens) -> Color {
        if quotaNotice != nil || usage != nil {
            return tokens.warning
        }
        if let goal {
            return goalStatusTint(goal, tokens: tokens)
        }
        return tokens.secondaryText
    }

    private func goalStatusTint(_ goal: ThreadGoal, tokens: ThemeTokens) -> Color {
        switch goal.status {
        case .active:
            return tokens.goalActive
        case .paused:
            return .secondary
        case .blocked, .usageLimited, .budgetLimited:
            return tokens.warning
        case .complete:
            return tokens.accent
        }
    }

    private func primaryGoalActionTitle(for status: ThreadGoalStatus) -> String {
        status == .active ? "暂停目标" : "继续目标"
    }

    private func primaryGoalActionSymbol(for status: ThreadGoalStatus) -> String {
        status == .active ? "pause.circle" : "play.circle"
    }

    private func collapsedGoalChipTitle(for status: ThreadGoalStatus) -> String {
        switch status {
        case .active:
            return "目标"
        case .paused:
            return "暂停"
        case .blocked:
            return "受阻"
        case .usageLimited:
            return "额度"
        case .budgetLimited:
            return "预算"
        case .complete:
            return "完成"
        }
    }
}

private struct AttachmentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var previewURL: URL?
    @State private var previewingLocalImagePath: String?
    @State private var localImagePreviewError: String?

    let item: CodexAppServerUserInput

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    previewContent(tokens: tokens)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(tokens.surface)
            .navigationTitle("附件预览")
            .navigationBarTitleDisplayMode(.inline)
            .quickLookPreview($previewURL)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func previewContent(tokens: ThemeTokens) -> some View {
        switch item {
        case .image(let url, _):
            if let image = Self.image(fromDataURL: url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if let remoteURL = URL(string: url),
                      let scheme = remoteURL.scheme?.lowercased(),
                      ["http", "https"].contains(scheme) {
                AsyncImage(url: remoteURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 180)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    case .failure:
                        previewMessage("图片加载失败", detail: url, tokens: tokens)
                    @unknown default:
                        previewMessage("图片加载失败", detail: url, tokens: tokens)
                    }
                }
            } else {
                previewMessage("无法预览这个图片引用", detail: url, tokens: tokens)
            }
        case .localImage(let path, _):
            localImagePreview(path: path, tokens: tokens)
        case .text(let text, _):
            previewMessage("文本附件", detail: text, tokens: tokens)
        case .skill(let name, let path):
            previewMessage("$\(name)", detail: path, tokens: tokens)
        case .mention(let name, let path):
            previewMessage("@\(name)", detail: path, tokens: tokens)
        }
    }

    private func localImagePreview(path: String, tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            previewMessage(
                "本机图片路径",
                detail: path + "\n发送时由本机 agentd 读取；也可以通过 agentd 安全读取授权范围内的文件并用 QuickLook 预览。",
                tokens: tokens
            )
            Button {
                Task { await previewLocalImage(path: path) }
            } label: {
                if previewingLocalImagePath == path {
                    Label("正在预览", systemImage: "hourglass")
                } else {
                    Label("预览文件", systemImage: "eye")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(previewingLocalImagePath != nil || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let localImagePreviewError {
                Text(localImagePreviewError)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func previewLocalImage(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            localImagePreviewError = "本机路径为空，无法预览。"
            return
        }

        previewingLocalImagePath = targetPath
        localImagePreviewError = nil
        defer {
            if previewingLocalImagePath == targetPath {
                previewingLocalImagePath = nil
            }
        }
        do {
            previewURL = try await sessionStore.previewFile(path: targetPath)
        } catch {
            localImagePreviewError = userFacingPreviewError(error)
        }
    }

    private func userFacingPreviewError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 || status == 405 {
            return "当前 agentd 版本还不支持文件预览，请升级 agentd。"
        }
        if case AgentAPIError.server(let status, _) = error, status == 403 {
            return "该文件不在授权范围内或不可访问。"
        }
        if case AgentAPIError.server(let status, _) = error, status == 413 {
            return "文件过大，暂不支持预览。"
        }
        return error.localizedDescription
    }

    private func previewMessage(_ title: String, detail: String, tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "photo")
                .font(themeStore.uiFont(.headline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
            Text(detail)
                .font(themeStore.codeFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func image(fromDataURL value: String) -> UIImage? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("data:image/"),
              let comma = trimmed.firstIndex(of: ",") else {
            return nil
        }
        let payload = trimmed[trimmed.index(after: comma)...]
        guard let data = Data(base64Encoded: String(payload), options: [.ignoreUnknownCharacters]) else {
            return nil
        }
        return UIImage(data: data)
    }
}

private struct AddContentPanel: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selectedPhotoItem: PhotosPickerItem?

    let skillShortcuts: [SkillCapability]
    let capabilityErrorMessage: String?
    let isRefreshingCapabilities: Bool
    let onPickImageFile: () -> Void
    let onManualInput: (ManualInputKind) -> Void
    let onSkillShortcut: (SkillCapability) -> Void
    let onRefreshCapabilities: () -> Void
    let onShortcut: (String) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            panelSection("图片") {
                LazyVGrid(columns: columns, spacing: 8) {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        panelActionLabel("图片", systemImage: "photo")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onPickImageFile()
                    } label: {
                        panelActionLabel("文件图片", systemImage: "doc.viewfinder")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onManualInput(.localImage)
                    } label: {
                        panelActionLabel("本机图片", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onManualInput(.imageURL)
                    } label: {
                        panelActionLabel("图片 URL", systemImage: "link")
                    }
                    .buttonStyle(.bordered)
                }
            }

            panelSection("快捷短语") {
                Menu {
                    ForEach(Self.shortcuts, id: \.self) { shortcut in
                        Button(shortcut) {
                            onShortcut(shortcut)
                        }
                    }
                } label: {
                    panelActionLabel("快捷短语", systemImage: "bolt")
                }
                .buttonStyle(.bordered)
            }

            panelSection("引用") {
                LazyVGrid(columns: columns, spacing: 8) {
                    Menu {
                        let error = capabilityErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
                        if skillShortcuts.isEmpty {
                            if let error, !error.isEmpty {
                                Text("Skill 列表不可用：\(error)")
                            } else {
                                Text("暂无可用 Skill")
                            }
                        } else {
                            Section("可用 Skill") {
                                ForEach(skillShortcuts.prefix(12)) { skill in
                                    Button {
                                        onSkillShortcut(skill)
                                    } label: {
                                        Label(skill.name, systemImage: "wand.and.stars")
                                    }
                                }
                            }
                        }
                        Divider()
                        Button {
                            onRefreshCapabilities()
                        } label: {
                            Label(isRefreshingCapabilities ? "刷新中" : "刷新 Skill 列表", systemImage: "arrow.clockwise")
                        }
                        .disabled(isRefreshingCapabilities)
                        Button {
                            onManualInput(.skill)
                        } label: {
                            Label("手动添加 Skill", systemImage: "square.and.pencil")
                        }
                    } label: {
                        panelActionLabel("Skill", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onManualInput(.mention)
                    } label: {
                        panelActionLabel("Mention", systemImage: "at")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .font(themeStore.uiFont(.callout))
        .padding(16)
        .frame(maxWidth: 360)
        .background(tokens.surface)
    }

    private func panelSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
            content()
        }
    }

    private func panelActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 30)
    }

    private static let shortcuts = [
        "检查这段实现并给出风险",
        "实现这个功能并补测试",
        "只做最小可运行版本，避免过度设计",
        "解释失败日志并给修复方案"
    ]
}

private struct VoiceMicButton: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isPressed = false

    let isPreparing: Bool
    let isRecording: Bool
    let isTranscribing: Bool
    let width: CGFloat
    let height: CGFloat
    let showsTitle: Bool
    let onPressChanged: (Bool) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let isActive = isPreparing || isRecording || isTranscribing
        let foreground = isRecording ? tokens.voiceRecording : tokens.accent
        let background = isRecording ? tokens.voiceRecording.opacity(0.15) : tokens.accent.opacity(isActive ? 0.14 : 0.10)
        let border = isRecording ? tokens.voiceRecording.opacity(0.5) : tokens.accent.opacity(isActive ? 0.54 : 0.42)

        VStack(spacing: showsTitle ? 8 : 0) {
            if isPreparing {
                ProgressView()
                    .controlSize(showsTitle ? .regular : .small)
                    .tint(foreground)
            } else {
                Image(systemName: isTranscribing ? "wand.and.stars" : isRecording ? "waveform.circle.fill" : "mic.fill")
                    .font(themeStore.uiFont(size: showsTitle ? 25 : 24, weight: .bold))
            }
            if showsTitle {
                Text(buttonTitle)
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .foregroundStyle(foreground)
        .frame(width: width, height: height)
        .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(border)
        }
        .shadow(color: isRecording ? tokens.voiceRecording.opacity(0.14) : .clear, radius: 10, y: 3)
        .scaleEffect(isActive ? 1.015 : 1)
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // 语音入口已经从工具栏里独立出来，长按手势只绑定在右侧整块主按钮上。
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else {
                        return
                    }
                    isPressed = true
                    onPressChanged(true)
                }
                .onEnded { _ in
                    guard isPressed else {
                        return
                    }
                    isPressed = false
                    onPressChanged(false)
                }
        )
        .onDisappear {
            guard isPressed else {
                return
            }
            isPressed = false
            onPressChanged(false)
        }
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint("按住把语音转写到草稿")
    }

    private var buttonTitle: String {
        if isTranscribing {
            return "转写中"
        }
        if isRecording {
            return "松手转写"
        }
        if isPreparing {
            return "准备中"
        }
        return "按住说话"
    }

    private var accessibilityTitle: String {
        if isRecording {
            return "正在录音，松手结束"
        }
        if isPreparing {
            return "正在准备麦克风"
        }
        return isTranscribing ? "正在转写语音" : "按住说话"
    }
}

struct VoiceWaveformLevelMapping {
    static let noiseGate: CGFloat = 0.035
    static let responseCurve: Double = 0.42
    static let audibleFloor: CGFloat = 0.10

    static func visualLevel(for rawLevel: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, rawLevel))
        guard clamped > noiseGate else {
            return 0
        }
        // 低音量区做更明显的视觉增益：静音仍被 gate 压住，一开口就能看到清楚的上下起伏。
        let normalized = (clamped - noiseGate) / (1 - noiseGate)
        let boosted = pow(Double(normalized), responseCurve)
        let lifted = audibleFloor + CGFloat(boosted) * (1 - audibleFloor)
        return max(0, min(1, lifted))
    }
}

struct VoiceWaveformSampleShape {
    static let barCount = 22

    static func samples(for rawLevel: CGFloat, count: Int = Self.barCount) -> [CGFloat] {
        let clamped = max(0, min(1, rawLevel))
        guard count > 0 else {
            return []
        }
        guard VoiceWaveformLevelMapping.visualLevel(for: clamped) > 0 else {
            return Array(repeating: 0, count: count)
        }

        return (0..<count).map { index in
            // 固定条位生成一个中间波峰：每一帧只反映“此刻声音大小”，不再把历史音量往前滚动。
            let progress = count == 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
            let distanceFromCenter = abs(progress - 0.5) * 2
            let bell = CGFloat(exp(-pow(Double(distanceFromCenter / 0.48), 2)))
            let shoulder: CGFloat = 0.16
            return min(1, clamped * (shoulder + bell * (1 - shoulder)))
        }
    }
}

private struct VoiceWaveformView: View {
    @ObservedObject var meter: VoiceLevelMeter
    let isActive: Bool
    let colors: [Color]

    var body: some View {
        GeometryReader { proxy in
            let samples = Array(meter.samples.enumerated())
            let spacing: CGFloat = 3
            let count = max(samples.count, 1)
            let availableWidth = max(0, proxy.size.width - spacing * CGFloat(max(count - 1, 0)))
            let barWidth = max(2.7, min(5.2, availableWidth / CGFloat(count)))

            // 用一条铺满整个宽度的横向渐变，再用竖条形状做 mask：每根条只露出它所在位置的渐变色，
            // 于是整组波形从左到右是平滑的主题渐变，而不是每根单独着色拼出来的硬边。
            LinearGradient(
                colors: colors,
                startPoint: .leading,
                endPoint: .trailing
            )
            .mask {
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(samples, id: \.offset) { index, level in
                        RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                            .frame(width: barWidth, height: barHeight(index: index, level: level, maxHeight: proxy.size.height))
                            .animation(.easeOut(duration: 0.07), value: level)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .opacity(isActive ? 1 : 0.45)
        }
    }

    private func barHeight(index: Int, level: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let minHeight: CGFloat = 3
        let usable = max(0, maxHeight - minHeight)
        guard isActive else {
            // 静止时给一点高低错落，避免看起来像坏掉的直线。
            return minHeight + (index.isMultiple(of: 2) ? 3 : 0)
        }
        let visibleLevel = VoiceWaveformLevelMapping.visualLevel(for: level)
        return minHeight + visibleLevel * usable
    }
}

@MainActor
private final class VoiceLevelMeter: ObservableObject {
    static let barCount = VoiceWaveformSampleShape.barCount

    @Published private(set) var samples: [CGFloat] = Array(repeating: 0, count: VoiceLevelMeter.barCount)
    private var previousLevel: CGFloat = 0

    func push(_ level: CGFloat) {
        let clamped = max(0, min(1, level))
        let risingDelta = max(0, clamped - previousLevel)
        // 只对“正在变大”的瞬间做一点 attack 增强；不保留历史队列，所以视觉不会横向滚动。
        let emphasizedLevel = min(1, clamped + risingDelta * 0.35)
        samples = VoiceWaveformSampleShape.samples(for: emphasizedLevel, count: Self.barCount)
        previousLevel = clamped
    }

    func prepareForRecording() {
        // 录音器刚启动但还没检测到声音时保持平线；一开口再按当前音量抬起中心波峰。
        samples = Array(repeating: 0, count: Self.barCount)
        previousLevel = 0
    }

    func reset() {
        samples = Array(repeating: 0, count: VoiceLevelMeter.barCount)
        previousLevel = 0
    }
}

@MainActor
private enum VoiceHaptics {
    private static let recordingStartGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private static let recordingReadyGenerator = UINotificationFeedbackGenerator()

    static func prepareRecordingStarted() {
        recordingStartGenerator.prepare()
        recordingReadyGenerator.prepare()
    }

    static func recordingStarted() {
        // 语音输入的唯一震动锚点：只有录音器已经开始采样后才震动。
        // 用户感受到这次反馈，就可以立即开口。
        recordingStartGenerator.impactOccurred(intensity: 1.0)
        recordingReadyGenerator.notificationOccurred(.success)
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        recordingStartGenerator.prepare()
        recordingReadyGenerator.prepare()
    }
}

private struct ManualUserInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ManualInputKind
    @State private var name = ""
    @State private var pathOrURL = ""

    let onAdd: (CodexAppServerUserInput) -> Void

    init(kind: ManualInputKind, onAdd: @escaping (CodexAppServerUserInput) -> Void) {
        _kind = State(initialValue: kind)
        self.onAdd = onAdd
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $kind) {
                    ForEach(ManualInputKind.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                if kind.requiresName {
                    TextField("名称", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                TextField(kind.valuePlaceholder, text: $pathOrURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle("添加引用")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        if let input {
                            onAdd(input)
                            dismiss()
                        }
                    }
                    .disabled(input == nil)
                }
            }
        }
    }

    private var input: CodexAppServerUserInput? {
        let value = pathOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .imageURL:
            return .image(url: value, detail: .auto)
        case .localImage:
            return .localImage(path: value, detail: .auto)
        case .skill:
            guard !title.isEmpty else {
                return nil
            }
            return .skill(name: title, path: value)
        case .mention:
            guard !title.isEmpty else {
                return nil
            }
            return .mention(name: title, path: value)
        }
    }
}

private enum ManualInputKind: String, CaseIterable, Identifiable {
    case imageURL
    case localImage
    case skill
    case mention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .imageURL:
            return "图片 URL"
        case .localImage:
            return "本机图片"
        case .skill:
            return "Skill"
        case .mention:
            return "Mention"
        }
    }

    var requiresName: Bool {
        switch self {
        case .skill, .mention:
            return true
        case .imageURL, .localImage:
            return false
        }
    }

    var valuePlaceholder: String {
        switch self {
        case .imageURL:
            return "https://... 或 data:image/..."
        case .localImage:
            return "app-server 可读取的绝对路径"
        case .skill, .mention:
            return "allowlist 内的路径"
        }
    }
}

private struct AdvancedTurnOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CodexAppServerTurnOptions
    @State private var configText: String
    @State private var outputSchemaText: String
    @State private var errorMessage: String?

    let onSave: (CodexAppServerTurnOptions) -> Void

    init(options: CodexAppServerTurnOptions, onSave: @escaping (CodexAppServerTurnOptions) -> Void) {
        _draft = State(initialValue: options)
        _configText = State(initialValue: Self.jsonText(from: options.config))
        _outputSchemaText = State(initialValue: Self.jsonText(from: options.outputSchema))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("模型") {
                    TextField("Runtime Provider", text: optionalStringBinding(\.runtimeProvider))
                    TextField("Model", text: optionalStringBinding(\.model))
                    TextField("Model Provider", text: optionalStringBinding(\.modelProvider))
                    TextField("Service Name", text: optionalStringBinding(\.serviceName))
                }

                Section("线程来源") {
                    TextField("Session Start Source", text: optionalStringBinding(\.sessionStartSource))
                    TextField("Thread Source", text: optionalStringBinding(\.threadSource))
                }

                Section("指令") {
                    TextEditor(text: optionalStringBinding(\.baseInstructions))
                        .frame(minHeight: 90)
                    TextEditor(text: optionalStringBinding(\.developerInstructions))
                        .frame(minHeight: 90)
                }

                Section("JSON") {
                    TextEditor(text: $configText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 110)
                    TextEditor(text: $outputSchemaText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 130)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("高级选项")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("清空") { clearAdvancedOptions() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { apply() }
                }
            }
        }
    }

    private func optionalStringBinding(_ keyPath: WritableKeyPath<CodexAppServerTurnOptions, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                draft[keyPath: keyPath] = trimmed.isEmpty ? nil : value
            }
        )
    }

    private func apply() {
        do {
            draft.config = try parseOptionalJSON(configText, requireObject: true, label: "config")
            draft.outputSchema = try parseOptionalJSON(outputSchemaText, requireObject: false, label: "outputSchema")
            onSave(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearAdvancedOptions() {
        draft.runtimeProvider = nil
        draft.modelProvider = nil
        draft.config = nil
        draft.baseInstructions = nil
        draft.developerInstructions = nil
        draft.outputSchema = nil
        draft.serviceName = nil
        draft.sessionStartSource = nil
        draft.threadSource = nil
        configText = ""
        outputSchemaText = ""
        errorMessage = nil
    }

    private func parseOptionalJSON(_ text: String, requireObject: Bool, label: String) throws -> CodexAppServerJSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let value = try JSONDecoder().decode(CodexAppServerJSONValue.self, from: Data(trimmed.utf8))
        if requireObject, value.objectValue == nil {
            throw AdvancedTurnOptionsError.invalidJSON(label + " 必须是 JSON object")
        }
        return value
    }

    private static func jsonText(from value: CodexAppServerJSONValue?) -> String {
        guard let value else {
            return ""
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private enum AdvancedTurnOptionsError: LocalizedError {
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let message):
            return message
        }
    }
}

@MainActor
private final class VoiceInputController: NSObject, ObservableObject {
    @Published private(set) var isPreparing = false
    @Published private(set) var isRecording = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeMessage: String?

    // 音量计单独成对象：波形按 buffer 频率刷新，只让 VoiceWaveformView 订阅它，
    // 避免高频 level 变化把整个 ComposerView 一起重绘。
    let levelMeter = VoiceLevelMeter()

    private var recorder: AVAudioRecorder?
    private var meteringTask: Task<Void, Never>?
    private var finishHandler: ((VoiceRecordingResult?) -> Void)?
    private var recordingURL: URL?
    private var startRequestID: UUID?
    private var pressStartedAt: Date?
    private var recordingStartedAt: Date?

    func start(onFinish: @escaping (VoiceRecordingResult?) -> Void) {
        guard !isRecording, finishHandler == nil else {
            return
        }
        let requestID = UUID()
        startRequestID = requestID
        finishHandler = onFinish
        pressStartedAt = Date()
        recordingStartedAt = nil
        errorMessage = nil
        noticeMessage = nil

        switch recordPermissionState() {
        case .undetermined:
            Task {
                // 首次系统权限弹窗可能吞掉按住手势结束事件；授权后不自动接着录，
                // 让用户重新按住一次，保证 UI 状态和真实录音起点一致。
                let granted = await requestRecordPermission()
                guard startRequestID == requestID else {
                    return
                }
                if granted {
                    noticeMessage = "麦克风已开启，请再按住说话"
                } else {
                    errorMessage = "麦克风权限未开启，请在系统设置中允许"
                }
                finish(fileURL: nil)
            }
            return
        case .denied:
            errorMessage = "麦克风权限未开启，请在系统设置中允许"
            finish(fileURL: nil)
            return
        case .granted:
            break
        }

        isPreparing = true
        VoiceHaptics.prepareRecordingStarted()

        Task {
            // 按住说话时权限弹窗可能晚于松手返回；用 requestID 防止松手后又启动录音。
            guard await requestRecordPermission() else {
                guard startRequestID == requestID else {
                    return
                }
                errorMessage = "麦克风权限未开启"
                finish(fileURL: nil)
                return
            }
            guard startRequestID == requestID else {
                return
            }
            do {
                try startRecording()
            } catch {
                guard startRequestID == requestID else {
                    return
                }
                errorMessage = error.localizedDescription
                finish(fileURL: nil)
            }
        }
    }

    func stop() {
        let shouldFinishImmediately = !isRecording && recorder == nil
        startRequestID = nil
        if shouldFinishImmediately {
            finish(fileURL: nil)
            return
        }
        finish(fileURL: recordingURL)
    }

    func cancel() {
        let fileURL = recordingURL
        startRequestID = nil
        finishHandler = nil
        finish(fileURL: nil)
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func setErrorMessage(_ message: String?) {
        errorMessage = message
        if message != nil {
            noticeMessage = nil
        }
    }

    func setNoticeMessage(_ message: String?) {
        noticeMessage = message
        if message != nil {
            errorMessage = nil
        }
    }

    func prewarm() {
        // 进入对话页时先把音频会话 category 配好（不激活、不触发麦克风指示灯）。
        // 这样真正按住说话时只需 setActive + record，省掉冷启动里最慢的 category 切换，
        // 缩短“按下 → 看到红色波形”的可感知延迟。
        guard recorder == nil, !isRecording else {
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [.duckOthers])
        VoiceHaptics.prepareRecordingStarted()
    }

    private func startRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw VoiceInputError.recordingFailed
        }
        self.recorder = recorder
        recordingURL = url
        recordingStartedAt = Date()
        levelMeter.prepareForRecording()
        isPreparing = false
        isRecording = true
        VoiceHaptics.recordingStarted()
        startMetering()
    }

    private func startMetering() {
        meteringTask?.cancel()
        meteringTask = Task { [weak self] in
            while !Task.isCancelled {
                // 45ms ≈ 22fps：比原来的 80ms 更跟手，波形随语音瞬态跳动而不是一卡一卡，
                // 同时仍远低于会让主线程吃紧的刷新频率。
                try? await Task.sleep(nanoseconds: 45_000_000)
                await MainActor.run {
                    guard let self, let recorder = self.recorder, self.isRecording else {
                        return
                    }
                    recorder.updateMeters()
                    let level = Self.normalizedPower(
                        average: recorder.averagePower(forChannel: 0),
                        peak: recorder.peakPower(forChannel: 0)
                    )
                    self.levelMeter.push(level)
                }
            }
        }
    }

    private func requestRecordPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func recordPermissionState() -> VoiceRecordPermissionState {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .undetermined:
                return .undetermined
            case .denied:
                return .denied
            case .granted:
                return .granted
            @unknown default:
                return .denied
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .undetermined:
                return .undetermined
            case .denied:
                return .denied
            case .granted:
                return .granted
            @unknown default:
                return .denied
            }
        }
    }

    private func finish(fileURL: URL?) {
        let now = Date()
        let pressDuration = pressStartedAt.map { now.timeIntervalSince($0) } ?? 0
        let recordedDuration = max(
            recorder?.currentTime ?? 0,
            recordingStartedAt.map { now.timeIntervalSince($0) } ?? 0
        )
        recorder?.stop()
        recorder = nil
        meteringTask?.cancel()
        meteringTask = nil
        recordingURL = nil
        startRequestID = nil
        pressStartedAt = nil
        recordingStartedAt = nil
        isPreparing = false
        isRecording = false
        levelMeter.reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let fileURL {
            finishHandler?(VoiceRecordingResult(
                fileURL: fileURL,
                recordedDuration: recordedDuration,
                pressDuration: pressDuration
            ))
        } else {
            finishHandler?(nil)
        }
        finishHandler = nil
    }

    nonisolated private static func normalizedPower(average: Float, peak: Float) -> CGFloat {
        // 以峰值为主、平均值兜底：峰值跟住人声爆破音，平均值避免纯底噪把波形误拉高。
        // 映射区间略收紧到 [-50, -4] dBFS，轻声会更早动起来，正常说话会明显上下波动。
        let floorDB: Float = -50
        let ceilDB: Float = -4
        let blended = max(average + 2, peak - 4)
        let clamped = max(floorDB, min(ceilDB, blended))
        return CGFloat((clamped - floorDB) / (ceilDB - floorDB))
    }
}

private struct VoiceRecordingResult {
    let fileURL: URL
    let recordedDuration: TimeInterval
    let pressDuration: TimeInterval
}

private struct VoiceTranscriptionContext: Equatable {
    let id = UUID()
    let sessionID: SessionID?
}

private struct RetryableVoiceTranscription: Identifiable {
    let id = UUID()
    let filename: String
    let contentType: String
    let audioData: Data
    let language: VoiceInputLanguage
    let recordedDuration: TimeInterval
    let pressDuration: TimeInterval
    let sessionID: SessionID?
}

private enum VoiceRecordPermissionState {
    case undetermined
    case denied
    case granted
}

private enum VoiceInputError: LocalizedError {
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .recordingFailed:
            return "录音启动失败"
        }
    }
}

struct TextSelectionPolicy {
    static func rangeAfterExternalTextSync(previousText: String, nextText: String, previousRange: NSRange) -> NSRange {
        let previousLength = utf16Length(of: previousText)
        let nextLength = utf16Length(of: nextText)
        let caretWasAtPreviousEnd = previousRange.length == 0 && previousRange.location >= previousLength
        if caretWasAtPreviousEnd {
            return NSRange(location: nextLength, length: 0)
        }
        return clampedRange(previousRange, in: nextText)
    }

    static func clampedRange(_ range: NSRange, in text: String) -> NSRange {
        let length = utf16Length(of: text)
        let location = min(max(0, range.location), length)
        let remaining = max(0, length - location)
        return NSRange(location: location, length: min(max(0, range.length), remaining))
    }

    private static func utf16Length(of text: String) -> Int {
        (text as NSString).length
    }
}

private struct ComposerTextSubmitSnapshot {
    let text: String
    let isComposing: Bool
}

private final class ComposerTextSubmitBridge {
    private weak var textView: CommandSubmitTextView?

    func attach(_ textView: CommandSubmitTextView) {
        self.textView = textView
    }

    func snapshotForSubmit() -> ComposerTextSubmitSnapshot? {
        guard let textView else {
            return nil
        }
        return ComposerTextSubmitSnapshot(
            text: textView.text ?? "",
            isComposing: textView.hasMarkedText
        )
    }
}

private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let submitBridge: ComposerTextSubmitBridge
    let font: UIFont
    let textColor: UIColor
    let tintColor: UIColor
    let externalTextRevision: Int
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let onSubmit: () -> Bool
    let onContentHeightChange: (CGFloat) -> Void
    let onCompositionStateChange: (Bool) -> Void
    let onVoiceShortcutPressChanged: (Bool) -> Void

    func makeUIView(context: Context) -> CommandSubmitTextView {
        let textView = CommandSubmitTextView()
        textView.delegate = context.coordinator
        textView.text = text
        context.coordinator.lastSyncedText = text
        context.coordinator.lastAppliedExternalRevision = externalTextRevision
        submitBridge.attach(textView)
        textView.onCommandSubmit = onSubmit
        textView.onContentLayoutChanged = { textView in
            context.coordinator.reportContentHeight(for: textView)
        }
        textView.onVoiceShortcutPressChanged = onVoiceShortcutPressChanged
        textView.backgroundColor = .clear
        textView.font = font
        textView.textColor = textColor
        textView.tintColor = tintColor
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = false
        textView.showsVerticalScrollIndicator = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.accessibilityLabel = "输入任务或后续指令"
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: CommandSubmitTextView, context: Context) {
        context.coordinator.parent = self
        submitBridge.attach(uiView)
        uiView.onCommandSubmit = onSubmit
        uiView.onContentLayoutChanged = { textView in
            context.coordinator.reportContentHeight(for: textView)
        }
        uiView.onVoiceShortcutPressChanged = onVoiceShortcutPressChanged
        context.coordinator.updateCompositionState(uiView.hasMarkedText)
        let shouldForceExternalTextSync = context.coordinator.lastAppliedExternalRevision != externalTextRevision

        // 字体/颜色只在真正变化时赋值：UITextView 的 font setter 会让 TextKit 对整段文本重新排版，
        // 打字时（尤其是中文 marked text 合成期间）每次按键都重设会打断输入法合成并造成可感知卡顿。
        var needsContentHeightReport = false
        if uiView.font != font {
            uiView.font = font
            needsContentHeightReport = true
        }
        if uiView.textColor != textColor {
            uiView.textColor = textColor
        }
        if uiView.tintColor != tintColor {
            uiView.tintColor = tintColor
        }

        if uiView.hasMarkedText, context.coordinator.lastSyncedText == text, !shouldForceExternalTextSync {
            // 中文/日文等输入法会先把拼音或假名放在 marked text 中。此时外层草稿仍是
            // 上一次已确认文本，不能把 SwiftUI 状态回灌到 UITextView，否则首个字母会被提交成正文。
            if needsContentHeightReport {
                context.coordinator.reportContentHeight(for: uiView)
            }
            return
        }

        guard context.coordinator.lastSyncedText != text || shouldForceExternalTextSync else {
            if needsContentHeightReport {
                context.coordinator.reportContentHeight(for: uiView)
            }
            return
        }

        // 外部清空/恢复草稿时才同步 UIKit 文本；用户正常输入由 delegate 单向写回，
        // 避免中文 marked text 和光标位置在 SwiftUI 重算时被反复重置。
        let previousText = uiView.text ?? ""
        let selectedRange = uiView.selectedRange
        context.coordinator.isApplyingExternalText = true
        uiView.text = text
        context.coordinator.lastSyncedText = text
        context.coordinator.lastAppliedExternalRevision = externalTextRevision
        context.coordinator.isApplyingExternalText = false
        context.coordinator.updateCompositionState(false)
        uiView.selectedRange = TextSelectionPolicy.rangeAfterExternalTextSync(
            previousText: previousText,
            nextText: text,
            previousRange: selectedRange
        )
        context.coordinator.reportContentHeight(for: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var isApplyingExternalText = false
        var lastSyncedText = ""
        var lastAppliedExternalRevision = 0
        private var lastReportedContentHeight: CGFloat = 0
        private var pendingContentHeight: CGFloat?
        private var isContentHeightReportScheduled = false
        private var isComposingText = false
        private var pendingCompositionState: Bool?
        private var isCompositionStateReportScheduled = false

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingExternalText else {
                return
            }
            let currentText = textView.text ?? ""
            let hasMarkedText = textView.hasMarkedText
            updateCompositionState(hasMarkedText)
            if !hasMarkedText {
                syncCommittedTextIfNeeded(currentText, force: false)
            }
            reportContentHeight(for: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingExternalText else {
                return
            }
            let hasMarkedText = textView.hasMarkedText
            updateCompositionState(hasMarkedText)
            if !hasMarkedText {
                // 部分输入法结束 marked text 时只触发 selection 变化；这里补一次收敛。
                syncCommittedTextIfNeeded(textView.text ?? "", force: false)
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard !isApplyingExternalText else {
                return
            }
            updateCompositionState(false)
            // 失焦是最后兜底边界，保证 UIKit 文本不会滞留在旧 draft 之外。
            syncCommittedTextIfNeeded(textView.text ?? "", force: true)
        }

        func updateCompositionState(_ isComposing: Bool) {
            guard isComposingText != isComposing else {
                return
            }
            isComposingText = isComposing
            pendingCompositionState = isComposing
            guard !isCompositionStateReportScheduled else {
                return
            }
            isCompositionStateReportScheduled = true
            // updateUIView 也会检查 marked text；状态回写放到下一拍，避免在 SwiftUI 更新周期内直接改 @State。
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.isCompositionStateReportScheduled = false
                guard let isComposing = self.pendingCompositionState else {
                    return
                }
                self.pendingCompositionState = nil
                self.parent.onCompositionStateChange(isComposing)
            }
        }

        func reportContentHeight(for textView: UITextView) {
            let height = visibleContentHeight(for: textView)
            guard abs(lastReportedContentHeight - height) > 0.5 else {
                return
            }
            pendingContentHeight = height
            guard !isContentHeightReportScheduled else {
                return
            }
            isContentHeightReportScheduled = true
            // UIKit 布局回调可能发生在 SwiftUI 更新周期里，异步并合并回写可避免
            // 长语音草稿编辑时 size/状态更新形成一串主线程抖动。
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.isContentHeightReportScheduled = false
                guard let height = self.pendingContentHeight else {
                    return
                }
                self.pendingContentHeight = nil
                guard abs(self.lastReportedContentHeight - height) > 0.5 else {
                    return
                }
                self.lastReportedContentHeight = height
                self.parent.onContentHeightChange(height)
            }
        }

        private func syncCommittedTextIfNeeded(_ currentText: String, force: Bool) {
            guard force || currentText != lastSyncedText || currentText != parent.text else {
                return
            }
            lastSyncedText = currentText
            if parent.text != currentText {
                parent.text = currentText
            }
        }

        private func visibleContentHeight(for textView: UITextView) -> CGFloat {
            let contentHeight = ceil(textView.contentSize.height)
            if contentHeight > 0 {
                return clampedVisibleHeight(contentHeight)
            }
            let width = max(textView.bounds.width, 1)
            let fittingSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            return clampedVisibleHeight(ceil(textView.sizeThatFits(fittingSize).height))
        }

        private func clampedVisibleHeight(_ height: CGFloat) -> CGFloat {
            min(max(height, parent.minHeight), parent.maxHeight)
        }
    }
}

private extension UITextView {
    var hasMarkedText: Bool {
        markedTextRange != nil
    }
}

private final class CommandSubmitTextView: UITextView {
    var onCommandSubmit: (() -> Bool)?
    var onContentLayoutChanged: ((CommandSubmitTextView) -> Void)?
    var onVoiceShortcutPressChanged: ((Bool) -> Void)?
    private var isVoiceShortcutPressed = false
    private var lastReportedLayoutWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        guard abs(bounds.width - lastReportedLayoutWidth) > 0.5 else {
            return
        }
        lastReportedLayoutWidth = bounds.width
        onContentLayoutChanged?(self)
    }

    override var keyCommands: [UIKeyCommand]? {
        let submit = UIKeyCommand(
            title: "发送",
            action: #selector(handleCommandReturn),
            input: "\r",
            modifierFlags: .command,
            discoverabilityTitle: "发送"
        )
        return (super.keyCommands ?? []) + [submit]
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if containsVoiceShortcutPress(presses) {
            guard !isVoiceShortcutPressed else {
                return
            }
            isVoiceShortcutPressed = true
            onVoiceShortcutPressChanged?(true)
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if containsVoiceShortcutPress(presses) {
            finishVoiceShortcutPress()
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if containsVoiceShortcutPress(presses) {
            finishVoiceShortcutPress()
            return
        }
        super.pressesCancelled(presses, with: event)
    }

    @objc private func handleCommandReturn() {
        // 普通回车仍由 UITextView 插入换行；只有 Command + Return 走发送。
        _ = onCommandSubmit?()
    }

    private func finishVoiceShortcutPress() {
        guard isVoiceShortcutPressed else {
            return
        }
        isVoiceShortcutPressed = false
        onVoiceShortcutPressChanged?(false)
    }

    private func containsVoiceShortcutPress(_ presses: Set<UIPress>) -> Bool {
        presses.contains { press in
            Self.isVoiceShortcutKey(press.key)
        }
    }

    private static func isVoiceShortcutKey(_ key: UIKey?) -> Bool {
        guard let key else {
            return false
        }
        switch key.keyCode {
        case .keyboardLANG1, .keyboardLANG2, .keyboardLANG3, .keyboardLANG4, .keyboardLANG5,
             .keyboardLANG6, .keyboardLANG7, .keyboardLANG8, .keyboardLANG9:
            // UIKit 没有公开 Fn/Globe 的专用 keyCode；部分硬件键盘会把输入法切换键上报为 LANG1...LANG9。
            return key.charactersIgnoringModifiers.isEmpty
        default:
            return false
        }
    }
}

private struct PendingApprovalActionCard: View {
    let approval: ApprovalSummary
    let isSendingDecision: Bool
    let onApprove: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text("等待审批")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    if isSendingDecision {
                        Label("决定已发送", systemImage: "hourglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(approval.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    approvalMeta
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            approvalButtons
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 审批是当前 turn 的阻塞点，放在输入框上方比放在 Inspector 更接近用户决策动作。
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.30), lineWidth: 1)
        }
    }

    private var approvalMeta: some View {
        HStack(spacing: 8) {
            Label(approval.kind, systemImage: "tag")
            if let count = approval.count {
                Label("\(count) 项", systemImage: "number")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var approvalButtons: some View {
        // 移动端触控优先：两个决策按钮等宽铺满、加大高度和字号，比并排小按钮更好点。
        HStack(spacing: 10) {
            Button(role: .destructive, action: onDecline) {
                Label("拒绝", systemImage: "xmark.circle")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isSendingDecision)

            Button(action: onApprove) {
                Label("批准", systemImage: "checkmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
            .disabled(isSendingDecision)
        }
    }
}

private struct PendingUserInputActionCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let request: AgentUserInputRequest
    let isSubmitting: Bool
    let onSubmit: ([String: [String]]) -> Void

    @State private var selectedAnswers: [String: String] = [:]
    @State private var freeformAnswers: [String: String] = [:]

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            header

            ForEach(request.questions) { question in
                questionBlock(question)
            }

            Button {
                onSubmit(answerPayload)
            } label: {
                if isSubmitting {
                    Label("提交中", systemImage: "hourglass")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                } else {
                    Label("提交补充信息", systemImage: "arrow.up.circle.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(tokens.accent)
            .controlSize(.large)
            .disabled(isSubmitting || !canSubmit)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.accent.opacity(0.28), lineWidth: 1)
        }
    }

    private var header: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.bubble")
                .font(.callout.weight(.semibold))
                .foregroundStyle(tokens.accent)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text("补充信息")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tokens.accent)
                Text(request.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if isSubmitting {
                    Label("答案已发送", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func questionBlock(_ question: AgentUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(question.header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(question.question)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !question.options.isEmpty {
                optionButtons(for: question)
            }
            if question.isOther || question.options.isEmpty {
                answerField(for: question)
            }
        }
    }

    private func optionButtons(for question: AgentUserInputQuestion) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(question.options) { option in
                let isSelected = selectedAnswers[question.id] == option.label
                Button {
                    selectedAnswers[question.id] = option.label
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(option.label, systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if let description = option.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                            Text(description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(isSelected ? tokens.accent : nil)
                .disabled(isSubmitting)
            }
        }
    }

    @ViewBuilder
    private func answerField(for question: AgentUserInputQuestion) -> some View {
        if question.isSecret {
            SecureField("Other", text: binding(for: question.id))
                .textFieldStyle(.roundedBorder)
                .disabled(isSubmitting)
        } else {
            TextField("Other", text: binding(for: question.id), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .disabled(isSubmitting)
        }
    }

    private func binding(for questionID: String) -> Binding<String> {
        Binding(
            get: { freeformAnswers[questionID] ?? "" },
            set: { freeformAnswers[questionID] = $0 }
        )
    }

    private var answerPayload: [String: [String]] {
        var payload: [String: [String]] = [:]
        for question in request.questions {
            let answers = answers(for: question)
            if !answers.isEmpty {
                payload[question.id] = answers
            }
        }
        return payload
    }

    private var canSubmit: Bool {
        if request.questions.isEmpty {
            return true
        }
        return request.questions.allSatisfy { !answers(for: $0).isEmpty }
    }

    private func answers(for question: AgentUserInputQuestion) -> [String] {
        var values: [String] = []
        if let selected = selectedAnswers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty {
            values.append(selected)
        }
        let freeform = (freeformAnswers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !freeform.isEmpty {
            values.append(freeform)
        }
        return values
    }
}
