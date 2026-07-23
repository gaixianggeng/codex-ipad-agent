import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

struct ComposerToolbarControlLabel: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let title: String?
    let systemImage: String
    let trailingSystemImage: String?
    let isSelected: Bool
    let tint: Color?
    let titleMaxWidth: CGFloat?
    let accessibilityLabel: String

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let foreground = isSelected ? tokens.primaryActionForeground : (tint ?? tokens.accent)

        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 14, weight: .semibold))
            if let title {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: titleMaxWidth, alignment: .leading)
            }
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(themeStore.uiFont(size: 13, weight: .bold))
                    .accessibilityHidden(true)
            }
        }
        .font(themeStore.uiFont(.caption, weight: .semibold))
        .foregroundStyle(foreground)
        .frame(height: 44)
        .padding(.horizontal, title == nil ? 0 : 12)
        .frame(minWidth: 44)
        .background(
            isSelected ? tokens.accent : tokens.surface,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .modifier(
            ComposerFlatControlSurface(
                tokens: tokens,
                cornerRadius: 12,
                isEmphasized: isSelected
            )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(accessibilityLabel)
    }
}

// ComposerView 的输入、语音和附件动作集中在这里；状态仍由主 View 持有，避免新增镜像 ViewModel。
extension ComposerView {
    var selectedVoiceInputProvider: VoiceInputProvider {
        // 商店版本固定走设备端实时转写；旧安装残留的 Codex 偏好不会重新启用远端转写。
        .apple
    }

    var isPhoneComposer: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    var canCollapsePhoneComposer: Bool {
        isPhoneComposer &&
            composerState.attachments.isEmpty &&
            !composerState.voiceDraftNeedsReview &&
            !isVoicePressActive &&
            !voiceInput.isPreparing &&
            !voiceInput.isRecording &&
            !isVoiceTranscribing &&
            activeSkillQuery == nil
    }

    var usesCollapsedPhoneComposer: Bool {
        isPhoneComposerCollapsed && canCollapsePhoneComposer
    }

    var collapsedPhoneComposerText: String {
        let text = composerState.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? composerPlaceholderText : text
    }

    func expandPhoneComposer() {
        guard isPhoneComposer else { return }
        isPhoneComposerCollapsed = false
        // 焦点请求只服务于这一次“点开输入框”；UITextView 消费后会清空 token，
        // 后续因附件或语音状态重建完整输入框时不会再次误弹键盘。
        composerTextFocusRequestID = UUID()
    }

    func collapsePhoneComposer() {
        guard canCollapsePhoneComposer else { return }
        // 先让输入法提交 marked text，再把最终文本同步回草稿；折叠只改变展示，不丢编辑状态。
        composerTextSubmitBridge.resignFirstResponder()
        synchronizeComposerTextBeforeDraftScopeChange()
        composerTextSubmitBridge.prepareForRemoval(text: composerState.draft)
        activeSkillQuery = nil
        isPhoneComposerCollapsed = true
    }

    func collapsePhoneComposerAfterSubmit() {
        guard isPhoneComposer else { return }
        // takeDraftForSubmit 已清空稳定草稿；移除 UIKit 编辑器前也清空其文本，避免失焦回调把已发送内容写回来。
        composerTextExternalRevision += 1
        composerTextSubmitBridge.prepareForRemoval(text: composerState.draft)
        activeSkillQuery = nil
        isPhoneComposerCollapsed = true
    }

    @ViewBuilder
    var attachmentStrip: some View {
        if !composerState.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(composerState.attachments.enumerated()), id: \.offset) { index, item in
                        attachmentChip(item, index: index)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func attachmentChip(_ item: CodexAppServerUserInput, index: Int) -> some View {
        if case .skill(let name, let path) = item {
            let capability = enabledSkillShortcuts.first { $0.path == path || $0.name == name }
            SkillAttachmentToken(
                metadata: SkillVisualMetadata(name: name, path: path, capability: capability),
                onOpen: canPreviewAttachment(item) ? { previewingAttachment = item } : nil,
                onRemove: { removeAttachment(item, at: index) }
            )
            .environmentObject(themeStore)
        } else {
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
                    removeAttachment(item, at: index)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .accessibilityLabel(L10n.text("ui.remove"))
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

    func removeAttachment(_ item: CodexAppServerUserInput, at index: Int) {
        composerState.removeAttachment(at: index)
        if previewingAttachment?.id == item.id {
            previewingAttachment = nil
        }
    }

    @ViewBuilder
    var attachmentErrorNotice: some View {
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
    var voiceErrorMessage: some View {
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
                            Label(L10n.text("ui.try_transcribing_again"), systemImage: "arrow.clockwise")
                        }
                    }
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isVoiceTranscribing)
                    .accessibilityLabel(L10n.text("ui.retry_speech_transcription"))
                    .help(L10n.text("ui.resubmit_the_recording_you_just_made"))
                }
                Button {
                    clearVoiceTransientStatus()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.medium)
                        .foregroundStyle(.red.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("ui.turn_off_speech_transcription_error_prompts"))
                .help(L10n.text("ui.close_prompt"))
            }
            .font(themeStore.uiFont(.caption))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    var voiceNoticeMessage: some View {
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

    @ViewBuilder
    var pendingApprovalAction: some View {
        if !sessionStore.isSelectedSessionObserving, let approval = sessionStore.selectedSession?.pendingApproval {
            PendingApprovalActionCard(
                approval: approval,
                isSendingDecision: sessionStore.isApprovalDecisionPending(approval),
                onDecision: { decision in
                    sessionStore.decideApproval(approval, decision: decision)
                }
            )
        }
    }

    @ViewBuilder
    var pendingUserInputAction: some View {
        if !sessionStore.isSelectedSessionObserving, let request = sessionStore.selectedSession?.pendingUserInput {
            if isPhoneComposer {
                PendingUserInputResumeButton(
                    request: request,
                    isSubmitting: sessionStore.isUserInputResponsePending(request),
                    action: { presentPendingUserInputSheet(request) }
                )
            } else {
                PendingUserInputActionCard(
                    request: request,
                    isSubmitting: sessionStore.isUserInputResponsePending(request),
                    draft: $pendingUserInputFormState.draft,
                    onSubmit: { answers in
                        sessionStore.respondToUserInput(request, answers: answers)
                    }
                )
                .id(PendingUserInputPresentation(request: request).id)
            }
        }
    }

    var pendingUserInputSelectionIdentity: PendingUserInputSelectionIdentity {
        let requestPresentationID = sessionStore.selectedSession?.pendingUserInput.map {
            PendingUserInputPresentation(request: $0).id
        }
        return PendingUserInputSelectionIdentity(
            sessionID: sessionStore.selectedSessionID,
            requestPresentationID: requestPresentationID
        )
    }

    func synchronizePendingUserInputPresentation(
        previous: PendingUserInputSelectionIdentity?,
        current: PendingUserInputSelectionIdentity
    ) {
        if previous?.sessionID != current.sessionID {
            // 会话切换意味着表单语境已经变化，旧选择不能带入另一条 thread。
            pendingUserInputFormState.resetForSessionChange()
            presentedPendingUserInput = nil
        }

        guard !sessionStore.isSelectedSessionObserving,
              let request = sessionStore.selectedSession?.pendingUserInput
        else {
            // 乐观提交会暂时移除请求。保留 draft 和 identity，异步失败恢复同一请求时
            // 可以自动重开并继续填写；真正的新请求会在下面按新 identity 重置。
            presentedPendingUserInput = nil
            return
        }

        let presentation = PendingUserInputPresentation(request: request)
        guard presentation.id == current.requestPresentationID else {
            return
        }
        pendingUserInputFormState.activate(presentation.id)
        if isPhoneComposer {
            presentedPendingUserInput = presentation
        }
    }

    func presentPendingUserInputSheet(_ request: AgentUserInputRequest) {
        let presentation = PendingUserInputPresentation(request: request)
        pendingUserInputFormState.activate(presentation.id)
        presentedPendingUserInput = presentation
    }

    func sendButton(showLabels: Bool) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let isGoalMode = composerState.isGoalModeSelected
        let isPlanMode = composerState.isPlanModeSelected
        let isGuidedFollowUp = !isGoalMode && !isPlanMode && canUseGuidedFollowUp && guidedFollowUpEnabled
        let title: String
        if composerState.voiceDraftNeedsReview {
            title = isGoalMode ? L10n.text("ui.confirm_target") : isPlanMode ? L10n.text("ui.confirm_plan") : isGuidedFollowUp ? L10n.text("ui.confirm_boot") : L10n.text("ui.confirm_sending")
        } else {
            title = isGoalMode ? L10n.text("ui.send_target") : isPlanMode ? L10n.text("ui.generate_plan") : isGuidedFollowUp ? L10n.text("ui.guide") : L10n.text("ui.send")
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
            .foregroundStyle(enabled ? tokens.primaryActionForeground : tokens.tertiaryText)
            .frame(height: 44)
            .padding(.horizontal, showLabels ? 18 : 0)
            .frame(minWidth: 44)
            .background(
                enabled ? tokens.primaryAction : tokens.surface,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .modifier(
                ComposerFlatControlSurface(
                    tokens: tokens,
                    cornerRadius: 12,
                    isEmphasized: enabled
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!enabled)
        .accessibilityLabel(isGoalMode ? L10n.text("ui.send_target_task") : (composerState.voiceDraftNeedsReview ? L10n.text("ui.confirm_sending_voice_draft") : L10n.text("ui.send")))
    }

    var permissionTitle: String {
        "\(composerState.permissionMode.title) · \(composerState.turnOptions.sandboxMode.title)"
    }

    var permissionWireSummary: String {
        "\(composerState.turnOptions.approvalPolicy.rawValue) · \(composerState.turnOptions.approvalsReviewer)"
    }

    var permissionTint: Color {
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

    var composerMinHeight: CGFloat {
        // 始终保留约三至四行的可点击编辑空间，输入第一行文字时也不缩小。输入区是页面
        // 主操作，不应退化成附着在工具栏上方的窄缝；更大的落点也更适合 iPad 键盘与触控笔。
        usesCompactComposerMetrics ? 72 : 92
    }

    var composerMaxHeight: CGFloat {
        if usesCompactComposerMetrics {
            return 220
        }
        return 300
    }

    var composerTextHeight: CGFloat {
        if usesCollapsedComposerTextHeight {
            return composerMinHeight
        }
        let measured = measuredComposerTextHeight > 0 ? measuredComposerTextHeight : composerMinHeight
        return min(max(measured, composerMinHeight), composerMaxHeight)
    }

    var usesCollapsedComposerTextHeight: Bool {
        // 清空草稿时忽略 UIKit 上一次测得的长文本高度，立即回到稳定的起始画布。
        composerState.isEmpty && !composerState.voiceDraftNeedsReview
    }

    var composerCardPadding: CGFloat {
        usesCompactComposerMetrics ? 12 : 14
    }

    var composerCardSpacing: CGFloat {
        12
    }

    var composerUIFont: UIFont {
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

    func beginHoldToTalk() {
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
        composerState.beginVoiceInput()
        let context = VoiceTranscriptionContext(sessionID: sessionStore.selectedSessionID)
        activeVoiceTranscriptionContext = context
        if selectedVoiceInputProvider == .apple {
            voiceInput.startAppleTranscription(
                locale: .autoupdatingCurrent,
                onTranscript: { transcript in
                    guard isVoiceTranscriptionContextCurrent(context) else { return }
                    composerState.applyRealtimeVoiceTranscript(transcript)
                },
                onFinish: {
                    isVoicePressActive = false
                    isVoiceTranscribing = false
                    if activeVoiceTranscriptionContext == context {
                        activeVoiceTranscriptionContext = nil
                    }
                    composerState.endVoiceInput()
                }
            )
            return
        }
        voiceInput.start { recording in
            isVoicePressActive = false
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
                await transcribeVoiceRecording(recording, context: context)
            }
        }
    }

    func endHoldToTalk() {
        guard isVoicePressActive || voiceInput.isPreparing || voiceInput.isRecording else {
            return
        }
        let releasedBeforeRecording = voiceInput.isPreparing && !voiceInput.isRecording
        isVoicePressActive = false
        if releasedBeforeRecording {
            // 点按模式下第二次点按发生在权限/录音准备期间，按取消处理，避免空录音进入转写。
            voiceInput.cancel()
            activeVoiceTranscriptionContext = nil
            composerState.endVoiceInput()
            return
        }
        if selectedVoiceInputProvider == .apple {
            // Apple 在录音过程中已持续写入草稿；停止后只等待最后一个稳定结果。
            isVoiceTranscribing = true
        }
        voiceInput.stop()
    }

    func toggleVoiceInput() {
        guard !isVoiceTranscribing else {
            return
        }
        if isVoicePressActive || voiceInput.isRecording {
            endHoldToTalk()
        } else {
            beginHoldToTalk()
        }
    }

    func toggleVoiceInputFromKeyboard() {
        toggleVoiceInput()
    }

    @MainActor
    func clearVoiceTransientStatus() {
        retryableVoiceTranscription = nil
        voiceInput.setErrorMessage(nil)
        voiceInput.setNoticeMessage(nil)
    }

    @MainActor
    func cancelVoiceInteraction(clearStatus: Bool) {
        // 切会话、离开页面或发送草稿时取消当前录音/转写；旧请求即使晚返回，也不能写入新会话的输入框。
        voiceTranscriptionTask?.cancel()
        voiceTranscriptionTask = nil
        activeVoiceTranscriptionContext = nil
        if isVoicePressActive || voiceInput.isPreparing || voiceInput.isRecording || isVoiceTranscribing {
            voiceInput.cancel()
        }
        isVoicePressActive = false
        isVoiceTranscribing = false
        composerState.endVoiceInput()
        if clearStatus {
            clearVoiceTransientStatus()
        }
    }

    func isVoiceTranscriptionContextCurrent(_ context: VoiceTranscriptionContext) -> Bool {
        activeVoiceTranscriptionContext == context && sessionStore.selectedSessionID == context.sessionID
    }

    @MainActor
    func autoDismissVoiceErrorIfNeeded(_ message: String?) async {
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

    func voiceErrorAutoDismissDelaySeconds(for message: String) -> UInt64 {
        if let retryAfter = Self.retryAfterSeconds(from: message) {
            // 429/临时不可用会给出 retry-after；提示至少保留到可重试窗口之后，
            // 但也设上限，避免底部红条永久占位。
            return UInt64(min(max(retryAfter + 5, 12), 45))
        }
        return 12
    }

    @MainActor
    func transcribeVoiceRecording(
        _ recording: VoiceRecordingResult,
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
                recordedDuration: usableDuration,
                pressDuration: recording.pressDuration,
                sessionID: context.sessionID
            )
            let response = try await sessionStore.transcribeVoice(
                filename: recording.fileURL.lastPathComponent,
                contentType: "audio/mp4",
                audioData: data,
                language: VoiceTranscriptionDefaults.languageCode
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

    func retryVoiceTranscription() {
        guard let retryableVoiceTranscription, !isVoiceTranscribing, voiceTranscriptionTask == nil else {
            return
        }
        guard retryableVoiceTranscription.sessionID == sessionStore.selectedSessionID else {
            self.retryableVoiceTranscription = nil
            voiceInput.setErrorMessage(L10n.text("ui.the_session_has_been_switched_please_record_again"))
            return
        }
        let context = VoiceTranscriptionContext(sessionID: retryableVoiceTranscription.sessionID)
        activeVoiceTranscriptionContext = context
        voiceTranscriptionTask = Task {
            await transcribeCachedVoiceRecording(retryableVoiceTranscription, context: context)
        }
    }

    @MainActor
    func transcribeCachedVoiceRecording(_ cached: RetryableVoiceTranscription, context: VoiceTranscriptionContext) async {
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
                language: VoiceTranscriptionDefaults.languageCode
            )
            try Task.checkCancellation()
            guard isVoiceTranscriptionContextCurrent(context) else {
                return
            }
            composerState.applyVoiceTranscript(response.text)
            if retryableVoiceTranscription?.id == cached.id {
                retryableVoiceTranscription = nil
            }
            voiceInput.setNoticeMessage(L10n.text("ui.the_voice_has_been_re_transcribed_please_confirm"))
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

    nonisolated static func voiceRecordingData(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
    }

    nonisolated static func safeVoiceRecordingDuration(_ url: URL) async -> TimeInterval {
        (try? await voiceRecordingDuration(url)) ?? 0
    }

    func shortVoiceRecordingMessage(recording: VoiceRecordingResult, usableDuration: TimeInterval) -> String {
        // 区分“用户真的很快松手”和“按住了但录音器实际采样很短”，避免把启动延迟误报成没按够 1 秒。
        if recording.pressDuration >= 0.9 && usableDuration < Self.minimumUsableVoiceDuration {
            return L10n.text("ui.the_microphone_starts_slowly_the_sound_just_recorded")
        }
        return L10n.text("ui.the_press_is_a_bit_short_please_hold")
    }

    nonisolated static func voiceRecordingDuration(_ url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    func userFacingVoiceTranscriptionError(_ error: Error, recording: VoiceRecordingResult? = nil) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return L10n.text("ui.voice_transcription_failed_please_try_again_later")
        }
        if message.contains("没有识别到语音内容") || message.contains("按住说话至少 1 秒") {
            if let recording, recording.pressDuration >= 0.9 {
                return L10n.text("ui.no_clear_voice_is_recognized_please_move_closer")
            }
            return L10n.text("ui.no_clear_voice_was_recognized_please_hold_down")
        }
        if Self.isTemporaryUnavailableVoiceErrorMessage(message) {
            if let seconds = Self.retryAfterSeconds(from: message) {
                return L10n.plural("ui.speech_retry_seconds_count", count: seconds)
            }
            return L10n.text("ui.speech_transcription_is_currently_unavailable_please_try_again_9e0e4eee")
        }
        if Self.isTimeoutVoiceErrorMessage(message) {
            return L10n.text("ui.the_speech_transcription_request_timed_out_please_try")
        }
        return L10n.format("ui.speech_transcription_failed", message)
    }

    nonisolated static func isRetryableVoiceTranscriptionError(_ error: Error) -> Bool {
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

    nonisolated static func isNonRetryableVoiceErrorMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("codex login")
            || message.contains("登录态已失效")
            || message.contains("麦克风权限")
            || message.contains("没有识别到语音内容")
            || message.contains("按住说话至少")
    }

    nonisolated static func isTemporaryUnavailableVoiceErrorMessage(_ message: String) -> Bool {
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

    nonisolated static func isTimeoutVoiceErrorMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("timed out")
            || lower.contains("timeout")
            || message.contains("超时")
    }

    nonisolated static func retryAfterSeconds(from message: String) -> Int? {
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

    func presentPhotoLibraryPicker() {
        let targetScope = activeComposerDraftScope
        let availableCount = remainingImageAttachmentCapacity(for: targetScope)
        guard availableCount > 0 else {
            attachmentErrorMessage = L10n.format("ui.at_most_images_can_be_added_to_each", Self.maximumImageAttachmentCount)
            showsAddContentPanel = false
            return
        }

        showsAddContentPanel = false
        let request = PhotoLibraryPickerRequest(
            selectionLimit: availableCount,
            targetScope: targetScope
        )
        Task { @MainActor in
            // 等承载入口的 popover 完成收起后再展示系统照片库，避免 iPad 上两个 presentation 竞争。
            await Task.yield()
            photoLibraryPickerRequest = request
        }
    }

    func loadPhotoAttachments(
        _ results: [PHPickerResult],
        targetScope: ComposerDraftScopeKey
    ) {
        let availableCount = remainingImageAttachmentCapacity(for: targetScope)
        let selectedResults = Array(results.prefix(availableCount))
        let skippedCount = max(0, results.count - selectedResults.count)
        guard !selectedResults.isEmpty else {
            attachmentErrorMessage = L10n.format("ui.at_most_images_can_be_added_to_each", Self.maximumImageAttachmentCount)
            return
        }

        Task {
            var preparedInputs: [CodexAppServerUserInput] = []
            var failedCount = 0
            var firstError: Error?

            // 串行读取和下采样，避免多张 iPad 截图同时完整解码造成瞬时内存峰值。
            for result in selectedResults {
                do {
                    let data = try await Self.loadImageData(from: result.itemProvider)
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try ImageAttachmentEncoder.prepare(data)
                    }.value
                    preparedInputs.append(.image(url: prepared.dataURL, detail: .auto))
                } catch {
                    failedCount += 1
                    firstError = firstError ?? error
                }
            }

            let addedCount = addPreparedImageAttachments(preparedInputs, to: targetScope)
            updateBatchAttachmentNotice(
                addedCount: addedCount,
                failedCount: failedCount,
                skippedCount: skippedCount + max(0, preparedInputs.count - addedCount),
                firstError: firstError
            )
        }
    }

    static func loadImageData(from provider: NSItemProvider) async throws -> Data {
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            throw PhotoLibraryPickerError.unsupportedImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: PhotoLibraryPickerError.unreadableImage)
                }
            }
        }
    }

    @MainActor
    func addPreparedImageAttachments(
        _ inputs: [CodexAppServerUserInput],
        to targetScope: ComposerDraftScopeKey
    ) -> Int {
        guard targetScope != .none, !inputs.isEmpty else {
            return 0
        }

        if targetScope == activeComposerDraftScope {
            let allowed = Array(inputs.prefix(remainingImageAttachmentCapacity(in: composerState.attachments)))
            composerState.attachments.append(contentsOf: allowed)
            // 异步图片任务可能在旧 ComposerView 已消失后才完成，必须直接写稳定仓，不能只依赖 onChange。
            sessionStore.saveComposerDraft(composerState.draftSnapshot(), for: targetScope)
            return allowed.count
        }

        // 图片处理期间如果用户切了会话，结果仍写回发起选择时的草稿，不能串到当前会话。
        var snapshot = sessionStore.composerDraft(for: targetScope)
        let allowed = Array(inputs.prefix(remainingImageAttachmentCapacity(in: snapshot.attachments)))
        snapshot.attachments.append(contentsOf: allowed)
        sessionStore.saveComposerDraft(snapshot, for: targetScope)
        return allowed.count
    }

    func remainingImageAttachmentCapacity(for scope: ComposerDraftScopeKey) -> Int {
        if scope == activeComposerDraftScope {
            return remainingImageAttachmentCapacity(in: composerState.attachments)
        }
        return remainingImageAttachmentCapacity(in: sessionStore.composerDraft(for: scope).attachments)
    }

    func remainingImageAttachmentCapacity(in attachments: [CodexAppServerUserInput]) -> Int {
        let imageCount = attachments.reduce(into: 0) { count, input in
            switch input {
            case .image, .localImage:
                count += 1
            case .text, .skill, .mention:
                break
            }
        }
        return max(0, Self.maximumImageAttachmentCount - imageCount)
    }

    @MainActor
    func updateBatchAttachmentNotice(
        addedCount: Int,
        failedCount: Int,
        skippedCount: Int,
        firstError: Error?
    ) {
        if failedCount == 0, skippedCount == 0 {
            attachmentErrorMessage = nil
        } else if addedCount > 0 {
            let omitted = failedCount + skippedCount
            attachmentErrorMessage = L10n.format("ui.pictures_have_been_added_and_have_not_been", addedCount, omitted)
        } else if skippedCount > 0, failedCount == 0 {
            attachmentErrorMessage = L10n.format("ui.at_most_images_can_be_added_to_each", Self.maximumImageAttachmentCount)
        } else if let firstError {
            attachmentErrorMessage = userFacingAttachmentError(firstError)
        } else {
            attachmentErrorMessage = L10n.text("ui.image_reading_failed")
        }
    }

    func canPreviewAttachment(_ item: CodexAppServerUserInput) -> Bool {
        switch item {
        case .image, .localImage:
            return true
        case .text, .skill, .mention:
            return false
        }
    }

    func userFacingAttachmentError(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? L10n.text("ui.image_reading_failed") : L10n.format("ui.image_reading_failed_20ce920a", message)
    }

    func attachmentSymbol(for item: CodexAppServerUserInput) -> String {
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
