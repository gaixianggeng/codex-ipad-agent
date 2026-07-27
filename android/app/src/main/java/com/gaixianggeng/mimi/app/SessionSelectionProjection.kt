package com.gaixianggeng.mimi.app

import com.gaixianggeng.mimi.core.model.ComposerSendMode

internal fun MainUiState.transitionToThreadShell(
    threadId: String,
    loading: Boolean,
): MainUiState = copy(
    selectedThreadId = threadId,
    messages = emptyList(),
    activeTurnId = null,
    awaitingTurnIdentity = false,
    guideActiveTurn = false,
    historyCursor = null,
    queuedTurns = emptyList(),
    queueLoading = false,
    composerText = "",
    composerImages = emptyList(),
    selectedSkillPaths = emptySet(),
    composerSendMode = ComposerSendMode.Standard,
    loading = loading,
    error = null,
)

internal fun MainUiState.transitionToSessionList(): MainUiState = copy(
    selectedThreadId = null,
    messages = emptyList(),
    activeTurnId = null,
    awaitingTurnIdentity = false,
    guideActiveTurn = false,
    historyCursor = null,
    queuedTurns = emptyList(),
    queueLoading = false,
    composerText = "",
    composerImages = emptyList(),
    selectedSkillPaths = emptySet(),
    composerSendMode = ComposerSendMode.Standard,
    attachmentLoading = false,
    voiceRecording = false,
    voiceTranscribing = false,
    filePreview = null,
    filePreviewLocalPath = null,
    filePreviewLoading = false,
    respondingToRequest = false,
)
