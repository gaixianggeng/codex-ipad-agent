package com.gaixianggeng.mimi.app

import android.net.Uri
import android.util.Base64
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.gaixianggeng.mimi.R
import com.gaixianggeng.mimi.core.media.DeviceSpeechException
import com.gaixianggeng.mimi.core.media.DeviceSpeechFailure
import com.gaixianggeng.mimi.core.model.AgentProject
import com.gaixianggeng.mimi.core.logging.DiagnosticLogPolicy
import com.gaixianggeng.mimi.core.model.AgentThread
import com.gaixianggeng.mimi.core.model.ApprovalRequest
import com.gaixianggeng.mimi.core.model.ApprovalDecisionPolicy
import com.gaixianggeng.mimi.core.model.ConversationActivity
import com.gaixianggeng.mimi.core.model.ConversationActivityCategory
import com.gaixianggeng.mimi.core.model.ConversationMessage
import com.gaixianggeng.mimi.core.model.ConversationAttachment
import com.gaixianggeng.mimi.core.model.ConversationAttachmentKind
import com.gaixianggeng.mimi.core.model.ConversationRole
import com.gaixianggeng.mimi.core.model.ComposerSendMode
import com.gaixianggeng.mimi.core.model.ConversationTurnLifecycle
import com.gaixianggeng.mimi.core.model.ConversationTimelineStateReducer
import com.gaixianggeng.mimi.core.model.ConversationHistoryPolicy
import com.gaixianggeng.mimi.core.model.CompletionReconciliationPolicy
import com.gaixianggeng.mimi.core.model.ConnectedAgent
import com.gaixianggeng.mimi.core.model.ConnectionProfile
import com.gaixianggeng.mimi.core.model.GitActionKind
import com.gaixianggeng.mimi.core.model.GitStatusResponse
import com.gaixianggeng.mimi.core.model.PairingClaimRequest
import com.gaixianggeng.mimi.core.model.UserInputRequest
import com.gaixianggeng.mimi.core.model.ThreadSearchResult
import com.gaixianggeng.mimi.core.model.SessionSearchPolicy
import com.gaixianggeng.mimi.core.model.ThreadListPolicy
import com.gaixianggeng.mimi.core.model.ModelOption
import com.gaixianggeng.mimi.core.model.ModelSelectionPolicy
import com.gaixianggeng.mimi.core.model.SkillCapability
import com.gaixianggeng.mimi.core.model.QueuedSkill
import com.gaixianggeng.mimi.core.model.QueuedTurn
import com.gaixianggeng.mimi.core.model.QueuedTurnPolicy
import com.gaixianggeng.mimi.core.model.QueuedTurnState
import com.gaixianggeng.mimi.core.model.ComposerDraft
import com.gaixianggeng.mimi.core.model.ImageAttachment
import com.gaixianggeng.mimi.core.model.FileReadResponse
import com.gaixianggeng.mimi.core.model.WorktreeCleanupResponse
import com.gaixianggeng.mimi.core.model.WorktreeListItem
import com.gaixianggeng.mimi.core.model.WorktreeBranchListResponse
import com.gaixianggeng.mimi.core.model.PluginCapability
import com.gaixianggeng.mimi.core.model.CapabilityPickerPolicy
import com.gaixianggeng.mimi.core.model.PermissionMode
import com.gaixianggeng.mimi.core.model.DoctorResults
import com.gaixianggeng.mimi.core.model.McpServerCapability
import com.gaixianggeng.mimi.core.model.ThreadGoal
import com.gaixianggeng.mimi.core.model.ThreadGoalStatus
import com.gaixianggeng.mimi.core.model.ReviewTargetKind
import com.gaixianggeng.mimi.core.model.SessionReminder
import com.gaixianggeng.mimi.core.model.SessionReminderPolicy
import com.gaixianggeng.mimi.core.model.ReviewStartPolicy
import com.gaixianggeng.mimi.core.model.RuntimeRoutingPolicy
import com.gaixianggeng.mimi.core.model.ThreadGoalTransitionPolicy
import com.gaixianggeng.mimi.core.model.SessionContextSnapshot
import com.gaixianggeng.mimi.core.model.SessionContextStateReducer
import com.gaixianggeng.mimi.core.model.DirectoryListResponse
import com.gaixianggeng.mimi.core.model.AgentCommandAction
import com.gaixianggeng.mimi.core.model.CommandActionRunResponse
import com.gaixianggeng.mimi.core.model.CommandActionPolicy
import com.gaixianggeng.mimi.core.model.GitPullRequestStatusResponse
import com.gaixianggeng.mimi.core.model.GitTestFlightStatusResponse
import com.gaixianggeng.mimi.core.model.RateLimitSummary
import com.gaixianggeng.mimi.core.model.ConnectionDiagnostic
import com.gaixianggeng.mimi.core.model.RelayDiagnosticsResponse
import com.gaixianggeng.mimi.core.model.TailscaleNetworkPathResponse
import com.gaixianggeng.mimi.core.notifications.RuntimeNotificationKind
import com.gaixianggeng.mimi.core.notifications.SessionNotificationRoute
import com.gaixianggeng.mimi.core.network.EndpointAssessment
import com.gaixianggeng.mimi.core.network.EndpointPolicy
import com.gaixianggeng.mimi.core.network.PairingLinkAssessment
import com.gaixianggeng.mimi.core.network.PairingLinkPolicy
import com.gaixianggeng.mimi.core.network.PairingLinkRejection
import com.gaixianggeng.mimi.core.network.AppServerClient
import com.gaixianggeng.mimi.core.network.AppServerEvent
import com.gaixianggeng.mimi.core.network.AppServerProjection
import com.gaixianggeng.mimi.core.network.SessionContextProjection
import com.gaixianggeng.mimi.core.network.AppServerStatus
import com.gaixianggeng.mimi.core.network.HistoryMediaErrorKind
import com.gaixianggeng.mimi.core.network.TurnLifecycleProjection
import com.gaixianggeng.mimi.core.network.historyMediaErrorKind
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import java.util.UUID

data class MainUiState(
    val endpoint: String = "",
    val token: String = "",
    val displayName: String = "",
    val loading: Boolean = false,
    val connected: ConnectedAgent? = null,
    val projects: List<AgentProject> = emptyList(),
    val selectedProjectId: String? = null,
    val threads: List<AgentThread> = emptyList(),
    val selectedThreadId: String? = null,
    val messages: List<ConversationMessage> = emptyList(),
    val conversationConnected: Boolean = false,
    val activeTurnId: String? = null,
    val awaitingTurnIdentity: Boolean = false,
    val guideActiveTurn: Boolean = false,
    val historyCursor: String? = null,
    val pendingApprovals: Map<String, ApprovalRequest> = emptyMap(),
    val pendingUserInputs: Map<String, UserInputRequest> = emptyMap(),
    val respondingToRequest: Boolean = false,
    val networkAvailable: Boolean = true,
    val credentialsInvalid: Boolean = false,
    val gitStatus: GitStatusResponse? = null,
    val gitLoading: Boolean = false,
    val error: String? = null,
    val pendingPairingLink: Uri? = null,
    val profiles: List<ConnectionProfile> = emptyList(),
    val activeProfileId: String? = null,
    val threadCursor: String? = null,
    val threadCursors: Map<String, String> = emptyMap(),
    val sessionSearchQuery: String = "",
    val sessionSearchResults: List<ThreadSearchResult> = emptyList(),
    val sessionSearchCursor: String? = null,
    val sessionSearchCursors: Map<String, String> = emptyMap(),
    val sessionSearchLoading: Boolean = false,
    val recentlyArchivedThread: AgentThread? = null,
    val modelOptions: List<ModelOption> = emptyList(),
    val selectedModelId: String? = null,
    val selectedReasoningEffort: String? = null,
    val skills: List<SkillCapability> = emptyList(),
    val plugins: List<PluginCapability> = emptyList(),
    val selectedSkillPaths: Set<String> = emptySet(),
    val composerSendMode: ComposerSendMode = ComposerSendMode.Standard,
    val capabilitiesLoading: Boolean = false,
    val queuedTurns: List<QueuedTurn> = emptyList(),
    val queueLoading: Boolean = false,
    val composerText: String = "",
    val composerImages: List<ImageAttachment> = emptyList(),
    val attachmentLoading: Boolean = false,
    val voiceRecording: Boolean = false,
    val voiceTranscribing: Boolean = false,
    val filePreview: FileReadResponse? = null,
    val filePreviewLocalPath: String? = null,
    val filePreviewLoading: Boolean = false,
    val worktrees: List<WorktreeListItem> = emptyList(),
    val worktreeBranches: WorktreeBranchListResponse? = null,
    val worktreeLoading: Boolean = false,
    val worktreeCleanupPreview: WorktreeCleanupResponse? = null,
    val themeMode: String = "system",
    val themePreset: String = "codex",
    val dynamicColor: Boolean = true,
    val uiFontPreset: String = "system",
    val codeFontPreset: String = "systemMono",
    val fontScale: Float = 1f,
    val keepScreenOn: Boolean = false,
    val permissionMode: PermissionMode = PermissionMode.FullAccess,
    val voiceMode: String = "codex",
    val deviceSpeechAvailable: Boolean = false,
    val languageTag: String = "system",
    val developerMode: Boolean = false,
    val historyDiagnostics: String? = null,
    val historyDiagnosticsLoading: Boolean = false,
    val doctorResults: DoctorResults? = null,
    val mcpServers: List<McpServerCapability> = emptyList(),
    val diagnosticsLoading: Boolean = false,
    val pinnedThreadIds: Set<String> = emptySet(),
    val threadGoals: Map<String, ThreadGoal> = emptyMap(),
    val sessionTokenUsage: Map<String, String> = emptyMap(),
    val goalLoading: Boolean = false,
    val reviewLoading: Boolean = false,
    val sessionReminders: Map<String, SessionReminder> = emptyMap(),
    val directoryListing: DirectoryListResponse? = null,
    val workspaceLoading: Boolean = false,
    val commandActions: List<AgentCommandAction> = emptyList(),
    val commandActionResult: CommandActionRunResponse? = null,
    val commandActionLoading: Boolean = false,
    val pullRequestStatus: GitPullRequestStatusResponse? = null,
    val pullRequestUrl: String? = null,
    val testFlightStatus: GitTestFlightStatusResponse? = null,
    val diagnosticLogs: List<String> = emptyList(),
    val rateLimits: RateLimitSummary? = null,
    val usageLoading: Boolean = false,
    val connectionDiagnostic: ConnectionDiagnostic? = null,
    val connectionDiagnosticLoading: Boolean = false,
    val relayDiagnostics: RelayDiagnosticsResponse? = null,
    val tailscaleNetworkPath: TailscaleNetworkPathResponse? = null,
    val availableRuntimeProviders: List<String> = listOf("codex"),
    val newSessionRuntimeProvider: String = "codex",
)

class MainViewModel(private val container: AppContainer) : ViewModel() {
    private val _state = MutableStateFlow(MainUiState(displayName = container.string(R.string.default_mac_name)))
    val state: StateFlow<MainUiState> = _state.asStateFlow()

    fun setEndpoint(value: String) = _state.update { it.copy(endpoint = value, error = null) }
    fun setToken(value: String) = _state.update { it.copy(token = value, error = null) }
    fun setDisplayName(value: String) = _state.update { it.copy(displayName = value, error = null) }
    fun setNewSessionRuntime(value: String) = _state.update {
        it.copy(newSessionRuntimeProvider = value.takeIf(it.availableRuntimeProviders::contains) ?: "codex")
    }
    fun setThemeMode(value: String) = viewModelScope.launch { container.appearanceStore.setThemeMode(value) }
    fun setThemePreset(value: String) = viewModelScope.launch { container.appearanceStore.setThemePreset(value) }
    fun setDynamicColor(value: Boolean) = viewModelScope.launch { container.appearanceStore.setDynamicColor(value) }
    fun setUiFontPreset(value: String) = viewModelScope.launch { container.appearanceStore.setUiFontPreset(value) }
    fun setCodeFontPreset(value: String) = viewModelScope.launch { container.appearanceStore.setCodeFontPreset(value) }
    fun setFontScale(value: Float) = viewModelScope.launch { container.appearanceStore.setFontScale(value) }
    fun resetAppearance() = viewModelScope.launch { container.appearanceStore.resetAppearance() }
    fun setKeepScreenOn(value: Boolean) = viewModelScope.launch { container.appearanceStore.setKeepScreenOn(value) }
    fun setPermissionMode(value: PermissionMode) = viewModelScope.launch { container.appearanceStore.setPermissionMode(value.wireName) }
    fun setVoiceMode(value: String) = viewModelScope.launch { container.appearanceStore.setVoiceMode(value) }
    fun setLanguageTag(value: String) = viewModelScope.launch { container.appearanceStore.setLanguageTag(value) }
    fun setDeveloperMode(value: Boolean) {
        if (!value) _state.update { it.copy(historyDiagnostics = null, historyDiagnosticsLoading = false) }
        viewModelScope.launch { container.appearanceStore.setDeveloperMode(value) }
    }
    private var appServer: AppServerClient? = null
    private var appServerEventsJob: Job? = null
    private var appServerStatusJob: Job? = null
    private var reconnectJob: Job? = null
    private var sessionSearchJob: Job? = null
    private var queuedDispatchJob: Job? = null
    private var draftSaveJob: Job? = null
    private var sessionSearchGeneration = 0L
    private var threadListGeneration = 0L
    private var activeToken: String? = null
    private var activeRuntimeProvider: String = "codex"
    private var appForeground = true
    private var pendingNotificationRoute: SessionNotificationRoute? = null
    private val commentaryAgentItemIds = mutableSetOf<String>()

    init {
        viewModelScope.launch {
            container.appearanceStore.preferences.collect { preferences ->
                _state.update {
                    it.copy(
                        themeMode = preferences.themeMode,
                        themePreset = preferences.themePreset,
                        dynamicColor = preferences.dynamicColor,
                        uiFontPreset = preferences.uiFontPreset,
                        codeFontPreset = preferences.codeFontPreset,
                        fontScale = preferences.fontScale,
                        keepScreenOn = preferences.keepScreenOn,
                        permissionMode = PermissionMode.fromWire(preferences.permissionMode),
                        voiceMode = preferences.voiceMode,
                        deviceSpeechAvailable = container.deviceSpeechTranscriber.isAvailable(),
                        languageTag = preferences.languageTag,
                        developerMode = preferences.developerMode,
                    )
                }
            }
        }
        viewModelScope.launch {
            container.networkMonitor.available.collect { available ->
                _state.update { it.copy(networkAvailable = available) }
                if (!available) {
                    reconnectJob?.cancel()
                    appServer?.suspendConnection()
                    _state.update { it.copy(conversationConnected = false) }
                } else {
                    scheduleReconnect()
                }
            }
        }
        viewModelScope.launch {
            val profiles = container.profileStore.profiles.first()
            val activeId = container.profileStore.activeProfileId.first()
            _state.update { it.copy(profiles = profiles, activeProfileId = activeId) }
            val profile = profiles.firstOrNull { it.id == activeId } ?: profiles.firstOrNull() ?: return@launch
            val savedToken = withContext(Dispatchers.IO) { container.credentialStore.read(profile.id) }
                ?.takeIf(String::isNotBlank) ?: return@launch
            _state.update {
                it.copy(endpoint = profile.endpoint, displayName = profile.displayName, token = savedToken)
            }
            refreshPinnedThreads()
            refreshSessionReminders()
            connectWithTimeout(10_000L)
        }
    }

    fun togglePinnedThread(threadId: String) {
        val profileId = _state.value.activeProfileId ?: return
        val pinned = threadId !in _state.value.pinnedThreadIds
        viewModelScope.launch {
            runCatching { container.pinnedThreadStore.setPinned(profileId, threadId, pinned) }
                .onSuccess {
                    if (_state.value.activeProfileId == profileId) {
                        _state.update { current ->
                            current.copy(pinnedThreadIds = if (pinned) current.pinnedThreadIds + threadId else current.pinnedThreadIds - threadId)
                        }
                    }
                }
                .onFailure { error -> showError(error.message ?: container.string(R.string.could_not_update_pinned_session)) }
        }
    }

    private fun refreshPinnedThreads() {
        val profileId = _state.value.activeProfileId ?: return _state.update { it.copy(pinnedThreadIds = emptySet()) }
        viewModelScope.launch {
            runCatching { container.pinnedThreadStore.threadIds(profileId) }
                .onSuccess { ids -> if (_state.value.activeProfileId == profileId) _state.update { it.copy(pinnedThreadIds = ids) } }
                .onFailure { error -> showError(error.message ?: container.string(R.string.could_not_load_pinned_sessions)) }
        }
    }

    fun setAppForeground(foreground: Boolean) {
        if (appForeground == foreground) return
        appForeground = foreground
        if (!foreground) {
            persistCurrentDraftImmediately(_state.value)
            if (_state.value.voiceRecording) {
                viewModelScope.launch { withContext(Dispatchers.IO) { container.voiceRecorder.cancel() } }
                _state.update { it.copy(voiceRecording = false) }
            }
            reconnectJob?.cancel()
            appServer?.suspendConnection()
            _state.update { it.copy(conversationConnected = false) }
        } else {
            refreshSessionReminders()
            scheduleReconnect()
        }
    }

    fun scheduleSessionReminder(threadId: String, delayMillis: Long) {
        require(delayMillis in 1..SessionReminderPolicy.MAX_DELAY_MILLIS)
        val snapshot = _state.value
        val profileId = snapshot.activeProfileId ?: return
        val thread = snapshot.threads.firstOrNull { it.id == threadId }
            ?: snapshot.sessionSearchResults.firstOrNull { it.thread.id == threadId }?.thread ?: return
        val projectId = snapshot.projects.firstOrNull { it.path == thread.cwd }?.id ?: return
        val now = System.currentTimeMillis()
        val reminder = SessionReminder(
            profileId = profileId,
            projectId = projectId,
            threadId = threadId,
            title = thread.preview.trim().take(SessionReminderPolicy.MAX_TITLE_CHARS)
                .ifBlank { container.string(R.string.untitled_session) },
            fireAtEpochMillis = Math.addExact(now, delayMillis),
            createdAtEpochMillis = now,
        )
        viewModelScope.launch {
            runCatching {
                container.sessionReminderStore.upsert(reminder)
                container.sessionReminderScheduler.schedule(reminder)
            }.onSuccess {
                if (_state.value.activeProfileId == profileId) _state.update { it.copy(sessionReminders = it.sessionReminders + (threadId to reminder)) }
            }.onFailure { error -> showError(error.message ?: container.string(R.string.could_not_schedule_reminder)) }
        }
    }

    fun clearSessionReminder(threadId: String) {
        val profileId = _state.value.activeProfileId ?: return
        val current = _state.value.sessionReminders[threadId] ?: return
        viewModelScope.launch {
            runCatching {
                container.sessionReminderStore.remove(profileId, threadId)
                container.sessionReminderScheduler.cancel(profileId, current.projectId, threadId)
            }.onSuccess { _state.update { it.copy(sessionReminders = it.sessionReminders - threadId) } }
                .onFailure { error -> showError(error.message ?: container.string(R.string.could_not_clear_reminder)) }
        }
    }

    private fun refreshSessionReminders() {
        val profileId = _state.value.activeProfileId ?: return _state.update { it.copy(sessionReminders = emptyMap()) }
        viewModelScope.launch {
            runCatching { container.sessionReminderStore.load(profileId) }
                .onSuccess { reminders -> if (_state.value.activeProfileId == profileId) _state.update { it.copy(sessionReminders = reminders.associateBy(SessionReminder::threadId)) } }
                .onFailure { error -> showError(error.message ?: container.string(R.string.could_not_load_reminders)) }
        }
    }

    fun selectProject(id: String) {
        persistCurrentDraftImmediately(_state.value)
        invalidateSessionSearch()
        _state.update { it.copy(selectedProjectId = id, selectedThreadId = null, messages = emptyList(), activeTurnId = null, awaitingTurnIdentity = false, guideActiveTurn = false, gitStatus = null, sessionSearchQuery = "", sessionSearchResults = emptyList(), queuedTurns = emptyList(), composerText = "", composerImages = emptyList(), selectedSkillPaths = emptySet(), composerSendMode = ComposerSendMode.Standard, commandActions = emptyList(), commandActionResult = null, pullRequestStatus = null, pullRequestUrl = null, testFlightStatus = null, worktreeBranches = null) }
        loadThreads(id)
        refreshGit()
        refreshWorktrees()
        refreshInspectorCapabilities()
        refreshComposerCapabilities()
    }

    fun selectThread(id: String) {
        val beforeSelection = _state.value
        persistCurrentDraftImmediately(beforeSelection)
        val thread = beforeSelection.threads.firstOrNull { it.id == id }
            ?: beforeSelection.sessionSearchResults.firstOrNull { it.thread.id == id }?.thread ?: return
        val previousThread = beforeSelection.selectedThreadId
            ?.takeIf { it != id }
            ?.let { previousId -> beforeSelection.threads.firstOrNull { it.id == previousId } }
        _state.update { current ->
            if (current.threads.any { it.id == id }) current
            else current.copy(threads = listOf(thread) + current.threads)
        }
        _state.update { it.transitionToThreadShell(id, loading = true) }
        refreshQueuedTurns()
        loadComposerDraft()
        viewModelScope.launch {
            runCatching {
                if (previousThread != null && previousThread.runtimeProvider == activeRuntimeProvider) {
                    runCatching { appServer?.unsubscribeThread(previousThread.id) }
                }
                val client = ensureRuntime(thread.runtimeProvider, thread.id)
                client.resumeThread(thread.id, thread.cwd, _state.value.permissionMode)
                refreshThreadGoal(id)
                refreshComposerCapabilities()
                refreshUsage()
                client.conversationPage(thread.id)
            }.onSuccess { page ->
                _state.update { current ->
                    if (current.selectedThreadId != id) {
                        current
                    } else {
                        val snapshotActiveTurnId = TurnLifecycleProjection.activeTurnFromMessages(page.messages)
                        val activeTurnId = current.activeTurnId ?: snapshotActiveTurnId
                        current.copy(
                            loading = false,
                            threads = mergeThreadContext(current.threads, id, page.context),
                            messages = ConversationTimelineStateReducer.mergeSnapshot(
                                current = current.messages,
                                snapshot = page.messages,
                            ),
                            historyCursor = page.nextCursor,
                            activeTurnId = activeTurnId,
                            awaitingTurnIdentity = activeTurnId == null &&
                                (current.awaitingTurnIdentity || TurnLifecycleProjection.contextIsBusy(page.context)),
                        )
                    }
                }
                if (_state.value.selectedThreadId == id) flushNextQueuedTurn()
            }.onFailure { error ->
                _state.update { current ->
                    if (current.selectedThreadId == id) {
                        current.copy(loading = false, error = error.message ?: container.string(R.string.could_not_resume_session))
                    } else {
                        current
                    }
                }
            }
        }
    }

    fun showSessionList() {
        val snapshot = _state.value
        if (snapshot.selectedThreadId == null) return
        persistCurrentDraftImmediately(snapshot)
        if (snapshot.voiceRecording) {
            viewModelScope.launch { withContext(Dispatchers.IO) { container.voiceRecorder.cancel() } }
        }
        _state.update(MainUiState::transitionToSessionList)
    }

    fun loadOlderMessages() {
        val snapshot = _state.value
        if (snapshot.loading) return
        val threadId = snapshot.selectedThreadId ?: return
        val cursor = snapshot.historyCursor ?: return
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            runCatching { requireNotNull(appServer).conversationPage(threadId, cursor) }
                .onSuccess { page -> _state.update { current ->
                    if (current.selectedThreadId == threadId) {
                        current.copy(
                            loading = false,
                            messages = ConversationTimelineStateReducer.prependSnapshot(
                                current = current.messages,
                                older = page.messages,
                            ),
                            historyCursor = ConversationHistoryPolicy.nextCursor(cursor, page.nextCursor),
                        )
                    } else {
                        current
                    }
                } }
                .onFailure { error -> _state.update { current ->
                    if (current.selectedThreadId == threadId) {
                        current.copy(loading = false, error = error.message ?: container.string(R.string.could_not_load_earlier_messages))
                    } else {
                        current
                    }
                } }
        }
    }

    fun newSession() {
        val project = selectedProject() ?: return
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            runCatching {
                ensureRuntime(_state.value.newSessionRuntimeProvider).startThread(project.path, _state.value.permissionMode)
            }
                .onSuccess { thread ->
                    _state.update {
                        it.copy(
                            loading = false,
                            threads = listOf(thread) + it.threads.filterNot { item -> item.id == thread.id },
                            selectedThreadId = thread.id,
                            messages = emptyList(),
                            activeTurnId = null,
                            awaitingTurnIdentity = false,
                            guideActiveTurn = false,
                            queuedTurns = emptyList(),
                            composerText = "",
                            composerImages = emptyList(),
                            composerSendMode = ComposerSendMode.Standard,
                        )
                    }
                    refreshComposerCapabilities()
                }
                .onFailure { error -> _state.update { it.copy(loading = false, error = error.message ?: container.string(R.string.could_not_create_session)) } }
        }
    }

    fun setSessionSearchQuery(value: String) {
        sessionSearchGeneration += 1
        val generation = sessionSearchGeneration
        sessionSearchJob?.cancel()
        val query = value.trim()
        _state.update {
            it.copy(
                sessionSearchQuery = value,
                sessionSearchResults = emptyList(),
                sessionSearchCursor = null,
                sessionSearchCursors = emptyMap(),
                sessionSearchLoading = query.isNotEmpty(),
            )
        }
        if (query.isEmpty()) return
        sessionSearchJob = viewModelScope.launch {
            delay(SessionSearchPolicy.DEBOUNCE_MILLIS)
            val result = runCatching {
                _state.value.availableRuntimeProviders.associateWith { runtime -> runtimeSearch(runtime, query) }
            }
            if (!SessionSearchPolicy.isCurrent(generation, sessionSearchGeneration, query, _state.value.sessionSearchQuery)) return@launch
            result.onSuccess { pages ->
                val projectPath = selectedProject()?.path
                val projection = SessionSearchPolicy.initial(pages, projectPath)
                _state.update { current -> current.copy(
                    sessionSearchLoading = false,
                    sessionSearchResults = projection.results,
                    sessionSearchCursor = projection.cursors.values.firstOrNull(),
                    sessionSearchCursors = projection.cursors,
                ) }
            }.onFailure { _state.update { current -> current.copy(sessionSearchLoading = false) } }
        }
    }

    fun loadMoreSessionSearch() {
        val snapshot = _state.value
        val query = snapshot.sessionSearchQuery.trim()
        val cursors = snapshot.sessionSearchCursors
        if (cursors.isEmpty()) return
        if (query.isEmpty() || snapshot.sessionSearchLoading) return
        val generation = sessionSearchGeneration
        viewModelScope.launch {
            _state.update { it.copy(sessionSearchLoading = true) }
            val result = runCatching { cursors.mapValues { (runtime, cursor) -> runtimeSearch(runtime, query, cursor) } }
            if (!SessionSearchPolicy.isCurrent(generation, sessionSearchGeneration, query, _state.value.sessionSearchQuery)) return@launch
            result.onSuccess { pages ->
                val path = selectedProject()?.path
                _state.update { current ->
                    val projection = SessionSearchPolicy.append(
                        existing = current.sessionSearchResults,
                        pages = pages,
                        previousCursors = cursors,
                        projectPath = path,
                    )
                    current.copy(
                        sessionSearchLoading = false,
                        sessionSearchResults = projection.results,
                        sessionSearchCursor = projection.cursors.values.firstOrNull(),
                        sessionSearchCursors = projection.cursors,
                    )
                }
            }.onFailure { _state.update { it.copy(sessionSearchLoading = false) } }
        }
    }

    fun loadMoreThreads() {
        val snapshot = _state.value
        val project = selectedProject() ?: return
        val cursors = snapshot.threadCursors
        if (cursors.isEmpty()) return
        if (snapshot.loading || snapshot.sessionSearchQuery.isNotBlank()) return
        val generation = threadListGeneration
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            runCatching {
                val results = cursors.mapValues { (runtime, cursor) ->
                    runCatching { runtimeThreads(runtime, project.path, cursor) }
                }
                val pages = results.mapNotNull { (runtime, result) -> result.getOrNull()?.let { runtime to it } }.toMap()
                if (pages.isEmpty()) throw requireNotNull(results.values.firstNotNullOfOrNull { it.exceptionOrNull() })
                pages
            }
                .onSuccess { pages ->
                    if (!ThreadListPolicy.isCurrent(generation, threadListGeneration, project.id, _state.value.selectedProjectId)) {
                        return@onSuccess
                    }
                    _state.update { current ->
                        val projection = ThreadListPolicy.append(current.threads, pages, cursors)
                        current.copy(
                            loading = false,
                            threads = contextualizeThreads(
                                incoming = projection.threads,
                                existing = current.threads,
                            ).sortedByDescending { it.updatedAtEpochSeconds ?: it.createdAtEpochSeconds ?: 0 },
                            threadCursor = projection.cursors.values.firstOrNull(),
                            threadCursors = projection.cursors,
                        )
                    }
                }
                .onFailure { error ->
                    if (ThreadListPolicy.isCurrent(generation, threadListGeneration, project.id, _state.value.selectedProjectId)) {
                        _state.update { it.copy(loading = false, error = error.message ?: container.string(R.string.could_not_load_more_sessions)) }
                    }
                }
        }
    }

    fun renameThread(threadId: String, name: String) {
        val normalized = name.trim()
        if (normalized.isEmpty()) return
        val thread = threadForId(threadId) ?: return
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            runCatching { ensureRuntime(thread.runtimeProvider).setThreadName(threadId, normalized) }
                .onSuccess { _state.update { current -> current.copy(
                    loading = false,
                    threads = current.threads.map { if (it.id == threadId) it.copy(preview = normalized) else it },
                    sessionSearchResults = current.sessionSearchResults.map { if (it.thread.id == threadId) it.copy(thread = it.thread.copy(preview = normalized)) else it },
                ) } }
                .onFailure { error -> _state.update { it.copy(loading = false, error = error.message ?: container.string(R.string.could_not_rename_session)) } }
        }
    }

    fun archiveThread(threadId: String) {
        val thread = _state.value.threads.firstOrNull { it.id == threadId }
            ?: _state.value.sessionSearchResults.firstOrNull { it.thread.id == threadId }?.thread ?: return
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            runCatching { ensureRuntime(thread.runtimeProvider).archiveThread(threadId) }
                .onSuccess {
                    _state.update { current ->
                        val next = if (current.selectedThreadId == threadId) {
                            current.transitionToSessionList()
                        } else {
                            current
                        }
                        next.copy(
                            loading = false,
                            threads = next.threads.filterNot { it.id == threadId },
                            sessionSearchResults = next.sessionSearchResults.filterNot { it.thread.id == threadId },
                            recentlyArchivedThread = thread,
                        )
                    }
                }
                .onFailure { error -> _state.update { it.copy(loading = false, error = error.message ?: container.string(R.string.could_not_archive_session)) } }
        }
    }

    fun restoreRecentlyArchived() {
        val thread = _state.value.recentlyArchivedThread ?: return
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            runCatching { ensureRuntime(thread.runtimeProvider).unarchiveThread(thread.id) }
                .onSuccess { _state.update { current -> current.copy(
                    loading = false,
                    threads = listOf(thread) + current.threads.filterNot { it.id == thread.id },
                    recentlyArchivedThread = null,
                ) } }
                .onFailure { error -> _state.update { it.copy(loading = false, error = error.message ?: container.string(R.string.could_not_restore_session)) } }
        }
    }

    fun compactThread(threadId: String) {
        val thread = threadForId(threadId) ?: return
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            runCatching { ensureRuntime(thread.runtimeProvider).compactThread(threadId) }
                .onSuccess { _state.update { it.copy(loading = false) } }
                .onFailure { error -> _state.update { it.copy(loading = false, error = error.message ?: container.string(R.string.could_not_compact_session)) } }
        }
    }

    fun refreshThreadGoal(threadId: String? = _state.value.selectedThreadId) {
        val resolvedThreadId = threadId ?: return
        val thread = threadForId(resolvedThreadId) ?: return
        viewModelScope.launch {
            _state.update { it.copy(goalLoading = true) }
            runCatching { ensureRuntime(thread.runtimeProvider).threadGoal(resolvedThreadId) }
                .onSuccess { goal ->
                    _state.update { current -> current.copy(
                        goalLoading = false,
                        threadGoals = if (goal == null) current.threadGoals - resolvedThreadId else current.threadGoals + (resolvedThreadId to goal),
                    ) }
                }
                .onFailure { error -> _state.update { it.copy(goalLoading = false, error = error.message ?: container.string(R.string.could_not_load_goal)) } }
        }
    }

    fun setThreadGoal(
        threadId: String,
        objective: String,
        status: ThreadGoalStatus,
        tokenBudgetText: String,
        onSuccess: () -> Unit = {},
    ) {
        val normalized = objective.trim()
        if (normalized.isEmpty()) return showError(container.string(R.string.goal_objective_required))
        val tokenBudget = tokenBudgetText.trim().takeIf(String::isNotEmpty)?.toLongOrNull()
        if (tokenBudgetText.isNotBlank() && (tokenBudget == null || tokenBudget <= 0)) return showError(container.string(R.string.token_budget_must_be_positive))
        val thread = threadForId(threadId) ?: return
        viewModelScope.launch {
            _state.update { it.copy(goalLoading = true, error = null) }
            runCatching { ensureRuntime(thread.runtimeProvider).setThreadGoal(threadId, normalized, status, tokenBudget) }
                .onSuccess { goal ->
                    _state.update { it.copy(goalLoading = false, threadGoals = it.threadGoals + (threadId to goal)) }
                    onSuccess()
                }
                .onFailure { error -> _state.update { it.copy(goalLoading = false, error = error.message ?: container.string(R.string.could_not_save_goal)) } }
        }
    }

    fun updateThreadGoalStatus(threadId: String, status: ThreadGoalStatus) {
        val thread = threadForId(threadId) ?: return
        val goal = _state.value.threadGoals[threadId] ?: return showError(container.string(R.string.refresh_goal_before_transition))
        if (!ThreadGoalTransitionPolicy.canTransition(goal.status, status)) {
            return showError(container.string(R.string.goal_transition_not_available))
        }
        viewModelScope.launch {
            _state.update { it.copy(goalLoading = true, error = null) }
            runCatching {
                ensureRuntime(thread.runtimeProvider).setThreadGoal(
                    threadId = threadId,
                    status = status,
                )
            }
                .onSuccess { goal ->
                    _state.update { it.copy(goalLoading = false, threadGoals = it.threadGoals + (threadId to goal)) }
                }
                .onFailure { error ->
                    _state.update { it.copy(goalLoading = false, error = error.message ?: container.string(R.string.could_not_update_goal)) }
                }
        }
    }

    fun clearThreadGoal(threadId: String, onSuccess: () -> Unit = {}) {
        val thread = threadForId(threadId) ?: return
        viewModelScope.launch {
            _state.update { it.copy(goalLoading = true, error = null) }
            runCatching { ensureRuntime(thread.runtimeProvider).clearThreadGoal(threadId) }
                .onSuccess {
                    _state.update { it.copy(goalLoading = false, threadGoals = it.threadGoals - threadId) }
                    onSuccess()
                }
                .onFailure { error -> _state.update { it.copy(goalLoading = false, error = error.message ?: container.string(R.string.could_not_clear_goal)) } }
        }
    }

    fun startReview(threadId: String, kind: ReviewTargetKind, value: String?) {
        val thread = threadForId(threadId) ?: return
        val hasActiveTurn = _state.value.selectedThreadId == threadId && _state.value.activeTurnId != null
        if (!ReviewStartPolicy.canStart(thread.context?.status, hasActiveTurn)) {
            return showError(container.string(R.string.wait_for_current_turn_before_review))
        }
        viewModelScope.launch {
            _state.update { it.copy(reviewLoading = true, error = null) }
            runCatching { ensureRuntime(thread.runtimeProvider).startReview(threadId, kind, value) }
                .onSuccess { result ->
                    updateThreadContext(threadId, SessionContextProjection.statusUpdate(threadId, "running"))
                    _state.update { current ->
                        if (current.selectedThreadId == threadId) {
                            current.copy(
                                reviewLoading = false,
                                activeTurnId = result.turnId ?: current.activeTurnId,
                                awaitingTurnIdentity = result.turnId == null && current.activeTurnId == null,
                            )
                        } else {
                            current.copy(reviewLoading = false)
                        }
                    }
                }
                .onFailure { error -> _state.update { it.copy(reviewLoading = false, error = error.message ?: container.string(R.string.could_not_start_review)) } }
        }
    }

    fun forkThread(threadId: String) {
        val thread = _state.value.threads.firstOrNull { it.id == threadId }
            ?: _state.value.sessionSearchResults.firstOrNull { it.thread.id == threadId }?.thread ?: return
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            runCatching { ensureRuntime(thread.runtimeProvider).forkThread(thread.id, thread.cwd, _state.value.permissionMode) }
                .onSuccess { fork ->
                    _state.update { current -> current.copy(
                        loading = false,
                        threads = listOf(fork) + current.threads.filterNot { it.id == fork.id },
                    ) }
                    selectThread(fork.id)
                }
                .onFailure { error -> _state.update { it.copy(loading = false, error = error.message ?: container.string(R.string.could_not_fork_session)) } }
        }
    }

    fun sendMessage(text: String) {
        val normalized = text.trim()
        val initialState = _state.value
        val thread = initialState.threads.firstOrNull { it.id == initialState.selectedThreadId } ?: return
        if (normalized.isEmpty() && initialState.composerImages.isEmpty()) return
        if (initialState.composerSendMode == ComposerSendMode.Goal && normalized.isEmpty()) {
            return showError(container.string(R.string.goal_objective_required))
        }
        val resolvedModel = ModelSelectionPolicy.resolve(
            requestedModelId = initialState.selectedModelId,
            advertised = initialState.modelOptions,
            runtimeProvider = thread.runtimeProvider,
        )
        val state = initialState.copy(
            modelOptions = ModelSelectionPolicy.options(initialState.modelOptions, thread.runtimeProvider),
            selectedModelId = resolvedModel.id,
            selectedReasoningEffort = initialState.selectedReasoningEffort
                ?: resolvedModel.defaultReasoningEffort,
        )
        if (
            state.modelOptions != initialState.modelOptions ||
            state.selectedModelId != initialState.selectedModelId ||
            state.selectedReasoningEffort != initialState.selectedReasoningEffort
        ) {
            _state.update {
                it.copy(
                    modelOptions = state.modelOptions,
                    selectedModelId = state.selectedModelId,
                    selectedReasoningEffort = state.selectedReasoningEffort,
                )
            }
        }
        val clientMessageId = UUID.randomUUID().toString()
        clearComposerDraft(state)
        if (
            state.composerSendMode.allowsGuidedFollowUp &&
            state.activeTurnId != null &&
            state.conversationConnected &&
            state.guideActiveTurn
        ) {
            val activeTurnId = state.activeTurnId
            val selectedSkills = state.skills.filter { it.path in state.selectedSkillPaths }
            _state.update {
                it.copy(
                    guideActiveTurn = false,
                    messages = it.messages + ConversationMessage(
                        clientMessageId,
                        ConversationRole.User,
                        normalized.ifEmpty { "[${state.composerImages.size} image attachment(s)]" },
                        attachments = state.composerImages.map { image ->
                            ConversationAttachment(ConversationAttachmentKind.Image, url = image.dataUrl)
                        },
                    ),
                )
            }
            viewModelScope.launch {
                runCatching {
                    requireNotNull(appServer).steerTurn(
                        thread.id,
                        activeTurnId,
                        normalized,
                        clientMessageId,
                        selectedSkills,
                        state.composerImages,
                    )
                }.onFailure { error ->
                    _state.update { current -> current.copy(
                        messages = current.messages.filterNot { it.id == clientMessageId },
                        composerText = normalized,
                        composerImages = state.composerImages,
                        error = container.string(R.string.could_not_guide_current_reply, error.message.orEmpty()),
                    ) }
                    persistCurrentDraftImmediately(_state.value)
                }
            }
            return
        }
        if (TurnLifecycleProjection.isBusy(state.activeTurnId, state.awaitingTurnIdentity) || !state.conversationConnected) {
            enqueueQueuedTurn(clientMessageId, thread, normalized, state)
            return
        }
        _state.update {
            it.copy(
                awaitingTurnIdentity = true,
                messages = it.messages + ConversationMessage(
                    clientMessageId,
                    ConversationRole.User,
                    normalized.ifEmpty { "[${state.composerImages.size} image attachment(s)]" },
                    attachments = state.composerImages.map { image ->
                        ConversationAttachment(ConversationAttachmentKind.Image, url = image.dataUrl)
                    },
                ),
            )
        }
        viewModelScope.launch {
            val selectedSkills = state.skills.filter { it.path in state.selectedSkillPaths }
            runCatching {
                val client = requireNotNull(appServer)
                val goal = if (state.composerSendMode == ComposerSendMode.Goal) {
                    client.setThreadGoal(
                        threadId = thread.id,
                        objective = normalized,
                        status = ThreadGoalStatus.Active,
                    )
                } else {
                    null
                }
                val turnId = client.startTurn(
                    thread.id,
                    thread.cwd,
                    normalized,
                    clientMessageId,
                    state.selectedModelId,
                    state.selectedReasoningEffort,
                    selectedSkills,
                    state.composerImages,
                    state.permissionMode,
                    state.composerSendMode,
                )
                goal to turnId
            }
                .onSuccess { (goal, turnId) ->
                    _state.update { current ->
                        if (current.selectedThreadId != thread.id) {
                            current
                        } else {
                            current.copy(
                                activeTurnId = turnId ?: current.activeTurnId,
                                awaitingTurnIdentity = turnId == null && current.activeTurnId == null,
                                composerSendMode = ComposerSendMode.Standard,
                                threadGoals = if (goal == null) {
                                    current.threadGoals
                                } else {
                                    current.threadGoals + (thread.id to goal)
                                },
                            )
                        }
                    }
                }
                .onFailure { error ->
                    if (
                        _state.value.selectedThreadId == thread.id &&
                        _state.value.activeTurnId != null
                    ) {
                        return@onFailure
                    }
                    _state.update { current -> current.copy(
                        messages = current.messages.filterNot { it.id == clientMessageId },
                        awaitingTurnIdentity = false,
                        error = container.string(R.string.send_outcome_uncertain, error.message.orEmpty()),
                    ) }
                    enqueueQueuedTurn(clientMessageId, thread, normalized, state, QueuedTurnState.NeedsConfirmation)
                }
        }
    }

    fun setGuideActiveTurn(enabled: Boolean) = _state.update {
        it.copy(
            guideActiveTurn = enabled &&
                it.composerSendMode.allowsGuidedFollowUp &&
                it.activeTurnId != null &&
                it.conversationConnected,
        )
    }

    fun setComposerSendMode(mode: ComposerSendMode) = _state.update {
        it.copy(
            composerSendMode = mode,
            guideActiveTurn = if (mode.allowsGuidedFollowUp) it.guideActiveTurn else false,
        )
    }

    fun setComposerText(text: String) {
        _state.update { it.copy(composerText = text) }
        val snapshot = _state.value
        val profileId = snapshot.activeProfileId ?: return
        val threadId = snapshot.selectedThreadId ?: return
        draftSaveJob?.cancel()
        draftSaveJob = viewModelScope.launch {
            delay(300)
            runCatching {
                container.composerDraftStore.save(
                    ComposerDraft(
                        profileId,
                        threadId,
                        text,
                        snapshot.composerImages,
                        System.currentTimeMillis(),
                        selectedDraftSkills(snapshot),
                    ),
                )
        }.onFailure { error -> _state.update { it.copy(error = error.message ?: container.string(R.string.could_not_save_draft)) } }
        }
    }

    fun addImageAttachments(uris: List<Uri>) {
        val available = (8 - _state.value.composerImages.size).coerceAtLeast(0)
        val selected = uris.take(available)
        if (selected.isEmpty()) {
            if (uris.isNotEmpty()) {
                showError(container.string(R.string.image_attachment_limit))
            }
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(attachmentLoading = true) }
            val prepared = mutableListOf<ImageAttachment>()
            var firstError: Throwable? = null
            selected.forEach { uri ->
                runCatching { container.prepareImage(uri) }
                    .onSuccess(prepared::add)
                    .onFailure { firstError = firstError ?: it }
            }
            _state.update { current -> current.copy(
                attachmentLoading = false,
                composerImages = (current.composerImages + prepared).take(8),
                error = firstError?.message ?: current.error,
            ) }
            persistCurrentDraftImmediately(_state.value)
        }
    }

    fun removeImageAttachment(id: String) {
        _state.update { it.copy(composerImages = it.composerImages.filterNot { image -> image.id == id }) }
        persistCurrentDraftImmediately(_state.value)
    }

    fun startVoiceRecording() {
        if (_state.value.voiceRecording || _state.value.voiceTranscribing) return
        viewModelScope.launch {
            runCatching { withContext(Dispatchers.IO) { container.voiceRecorder.start() } }
                .onSuccess { _state.update { it.copy(voiceRecording = true, error = null) } }
                .onFailure { error -> _state.update { it.copy(error = error.message ?: container.string(R.string.could_not_start_recording)) } }
        }
    }

    fun startVoiceInput() {
        if (_state.value.voiceMode != "device") return startVoiceRecording()
        if (_state.value.voiceRecording || _state.value.voiceTranscribing) return
        viewModelScope.launch {
            _state.update { it.copy(voiceTranscribing = true, error = null) }
            runCatching { container.deviceSpeechTranscriber.transcribe() }
                .onSuccess { text ->
                    val current = _state.value.composerText
                    setComposerText(listOf(current.trimEnd(), text.trim()).filter(String::isNotBlank).joinToString(" "))
                    _state.update { it.copy(voiceTranscribing = false) }
                }
                .onFailure { error ->
                    if (error is CancellationException) throw error
                    val message = when ((error as? DeviceSpeechException)?.reason) {
                        DeviceSpeechFailure.Audio -> container.string(R.string.speech_audio_failed)
                        DeviceSpeechFailure.Permission -> container.string(R.string.microphone_permission_required)
                        DeviceSpeechFailure.ModelUnavailable -> container.string(R.string.speech_model_unavailable)
                        DeviceSpeechFailure.ModelDownloadScheduled -> container.string(R.string.speech_model_download_scheduled)
                        DeviceSpeechFailure.UnsupportedLanguage -> container.string(R.string.speech_language_unsupported)
                        DeviceSpeechFailure.NoMatch -> container.string(R.string.speech_no_match)
                        DeviceSpeechFailure.Busy -> container.string(R.string.speech_busy)
                        DeviceSpeechFailure.NoSpeech -> container.string(R.string.speech_no_speech)
                        DeviceSpeechFailure.Generic, null ->
                            error.message ?: container.string(R.string.speech_recognition_failed)
                    }
                    _state.update { it.copy(voiceTranscribing = false, error = message) }
                }
        }
    }

    fun stopVoiceAndTranscribe() {
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        if (!_state.value.voiceRecording || _state.value.voiceTranscribing) return
        viewModelScope.launch {
            _state.update { it.copy(voiceRecording = false, voiceTranscribing = true, error = null) }
            var recording: java.io.File? = null
            try {
                recording = withContext(Dispatchers.IO) { container.voiceRecorder.stop() }
                val bytes = withContext(Dispatchers.IO) { recording.readBytes() }
                check(bytes.size <= 12 * 1024 * 1024) { container.string(R.string.voice_recording_too_large) }
                val response = container.apiClient.transcribeVoice(
                    connection.profile.endpoint,
                    token,
                    recording.name,
                    "audio/mp4",
                    Base64.encodeToString(bytes, Base64.NO_WRAP),
                )
                val current = _state.value.composerText
                setComposerText(listOf(current.trimEnd(), response.text.trim()).filter(String::isNotBlank).joinToString(" "))
                _state.update { it.copy(voiceTranscribing = false) }
            } catch (failure: Throwable) {
                if (failure is CancellationException) throw failure
            _state.update { it.copy(voiceTranscribing = false, error = failure.message ?: container.string(R.string.voice_transcription_failed)) }
            } finally {
                withContext(Dispatchers.IO) { recording?.delete() }
            }
        }
    }

    fun cancelVoiceRecording() {
        container.deviceSpeechTranscriber.cancel()
        viewModelScope.launch { withContext(Dispatchers.IO) { container.voiceRecorder.cancel() } }
        _state.update { it.copy(voiceRecording = false, voiceTranscribing = false) }
    }

    fun previewFile(path: String) {
        val normalized = path.trim()
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        if (normalized.isEmpty()) return
        viewModelScope.launch {
            _state.update { it.copy(filePreviewLoading = true, error = null) }
            runCatching {
                val response = container.apiClient.readFile(connection.profile.endpoint, token, normalized)
                response to container.materializePreview(response)
            }.onSuccess { (response, localPath) ->
                _state.update { it.copy(filePreviewLoading = false, filePreview = response, filePreviewLocalPath = localPath) }
            }.onFailure { error ->
                _state.update { it.copy(filePreviewLoading = false, error = error.message ?: container.string(R.string.could_not_preview_file)) }
            }
        }
    }

    fun previewHistoryMedia(id: String) {
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(filePreviewLoading = true, error = null) }
            runCatching {
                val response = container.apiClient.readHistoryMedia(connection.profile.endpoint, token, id)
                response to container.materializePreview(response)
            }.onSuccess { (response, localPath) ->
                _state.update { it.copy(filePreviewLoading = false, filePreview = response, filePreviewLocalPath = localPath) }
            }.onFailure { error ->
                val message = when (historyMediaErrorKind(error)) {
                    HistoryMediaErrorKind.Expired -> container.string(R.string.history_media_expired)
                    HistoryMediaErrorKind.Unsupported -> container.string(R.string.history_media_unsupported)
                    HistoryMediaErrorKind.Other -> error.message ?: container.string(R.string.history_media_load_failed)
                }
                _state.update { it.copy(filePreviewLoading = false, error = message) }
            }
        }
    }

    fun clearFilePreview() = _state.update { it.copy(filePreview = null, filePreviewLocalPath = null) }

    private fun loadComposerDraft() {
        val profileId = _state.value.activeProfileId ?: return
        val threadId = _state.value.selectedThreadId ?: return
        viewModelScope.launch {
            runCatching { container.composerDraftStore.load(profileId, threadId) }
                .onSuccess { draft ->
                    if (_state.value.activeProfileId == profileId && _state.value.selectedThreadId == threadId) {
                        _state.update { current ->
                            val draftSkills = draft?.skills.orEmpty()
                            val existingPaths = current.skills.mapTo(mutableSetOf()) { it.path }
                            val restoredSkills = draftSkills
                                .filterNot { it.path in existingPaths }
                                .map {
                                    SkillCapability(
                                        name = it.name,
                                        description = null,
                                        scope = "draft",
                                        path = it.path,
                                        enabled = true,
                                        isManual = true,
                                    )
                                }
                            current.copy(
                                composerText = draft?.text.orEmpty(),
                                composerImages = draft?.images.orEmpty(),
                                skills = current.skills + restoredSkills,
                                selectedSkillPaths = draftSkills.mapTo(mutableSetOf()) { it.path },
                            )
                        }
                    }
                }
                .onFailure { error -> _state.update { it.copy(error = error.message ?: container.string(R.string.could_not_load_draft)) } }
        }
    }

    private fun clearComposerDraft(snapshot: MainUiState) {
        val profileId = snapshot.activeProfileId ?: return
        val threadId = snapshot.selectedThreadId ?: return
        draftSaveJob?.cancel()
        _state.update { it.copy(composerText = "", composerImages = emptyList(), selectedSkillPaths = emptySet()) }
        viewModelScope.launch {
            runCatching { container.composerDraftStore.remove(profileId, threadId) }
                .onFailure { error -> _state.update { it.copy(error = error.message ?: container.string(R.string.could_not_clear_sent_draft)) } }
        }
    }

    private fun persistCurrentDraftImmediately(snapshot: MainUiState) {
        val profileId = snapshot.activeProfileId ?: return
        val threadId = snapshot.selectedThreadId ?: return
        draftSaveJob?.cancel()
        draftSaveJob = viewModelScope.launch {
            runCatching {
                container.composerDraftStore.save(
                    ComposerDraft(
                        profileId,
                        threadId,
                        snapshot.composerText,
                        snapshot.composerImages,
                        System.currentTimeMillis(),
                        selectedDraftSkills(snapshot),
                    ),
                )
            }.onFailure { error -> _state.update { it.copy(error = error.message ?: container.string(R.string.could_not_save_draft)) } }
        }
    }

    private fun selectedDraftSkills(snapshot: MainUiState): List<QueuedSkill> =
        snapshot.skills
            .filter { it.path in snapshot.selectedSkillPaths }
            .map { QueuedSkill(it.name, it.path) }

    private fun enqueueQueuedTurn(
        id: String,
        thread: AgentThread,
        text: String,
        snapshot: MainUiState,
        initialState: QueuedTurnState = QueuedTurnState.Waiting,
    ) {
        val profileId = snapshot.activeProfileId ?: return
        val item = QueuedTurn(
            id = id,
            profileId = profileId,
            threadId = thread.id,
            cwd = thread.cwd,
            text = text,
            createdAtEpochMillis = System.currentTimeMillis(),
            model = snapshot.selectedModelId,
            effort = snapshot.selectedReasoningEffort,
            skills = snapshot.skills.filter { it.path in snapshot.selectedSkillPaths }.map { QueuedSkill(it.name, it.path) },
            images = snapshot.composerImages,
            permissionMode = snapshot.permissionMode.wireName,
            collaborationMode = snapshot.composerSendMode.wireName,
            goalObjective = normalizedGoalObjective(snapshot.composerSendMode, text),
            state = initialState,
        )
        viewModelScope.launch {
            runCatching { container.queuedTurnStore.enqueue(item) }
                .onSuccess {
                    if (_state.value.activeProfileId == item.profileId && _state.value.selectedThreadId == item.threadId) {
                        _state.update {
                            it.copy(
                                queuedTurns = it.queuedTurns + item,
                                composerSendMode = if (
                                    initialState == QueuedTurnState.Waiting &&
                                    it.composerSendMode.wireName == item.collaborationMode
                                ) {
                                    ComposerSendMode.Standard
                                } else {
                                    it.composerSendMode
                                },
                            )
                        }
                    }
                    flushNextQueuedTurn()
                }
                .onFailure { error ->
                    if (_state.value.activeProfileId == item.profileId && _state.value.selectedThreadId == item.threadId && _state.value.composerText.isBlank() && _state.value.composerImages.isEmpty()) {
                        _state.update { it.copy(composerText = text, composerImages = snapshot.composerImages) }
                        persistCurrentDraftImmediately(_state.value)
                    }
                _state.update { it.copy(error = error.message ?: container.string(R.string.could_not_queue_message)) }
                }
        }
    }

    fun editQueuedTurn(
        id: String,
        text: String,
        images: List<ImageAttachment>,
        skills: List<QueuedSkill>,
    ) {
        val normalized = text.trim()
        if (normalized.isEmpty() && images.isEmpty() && skills.isEmpty()) return
        viewModelScope.launch {
            runCatching { container.queuedTurnStore.updatePayload(id, normalized, images, skills) }
                .onSuccess {
                    _state.update {
                        it.copy(queuedTurns = it.queuedTurns.map { item ->
                            if (item.id == id) item.copy(
                                text = normalized,
                                images = images,
                                skills = skills,
                                goalObjective = normalized.takeIf { item.goalObjective != null },
                                lastError = null,
                            ) else item
                        })
                    }
                }
                .onFailure { error -> _state.update { it.copy(error = error.message ?: container.string(R.string.could_not_edit_queued_message)) } }
        }
    }

    fun deleteQueuedTurn(id: String) {
        viewModelScope.launch {
            runCatching { container.queuedTurnStore.remove(id) }
                .onSuccess { _state.update { it.copy(queuedTurns = it.queuedTurns.filterNot { item -> item.id == id }) } }
                .onFailure { error -> _state.update { it.copy(error = error.message ?: container.string(R.string.could_not_delete_queued_message)) } }
        }
    }

    fun retryQueuedTurn(id: String) {
        viewModelScope.launch {
            runCatching { container.queuedTurnStore.updateState(id, QueuedTurnState.Waiting) }
                .onSuccess {
                    _state.update { it.copy(queuedTurns = it.queuedTurns.map { item -> if (item.id == id) item.copy(state = QueuedTurnState.Waiting, lastError = null) else item }) }
                    flushNextQueuedTurn()
                }
                .onFailure { error -> _state.update { it.copy(error = error.message ?: container.string(R.string.could_not_retry_queued_message)) } }
        }
    }

    fun moveQueuedTurn(id: String, delta: Int) {
        if (delta == 0) return
        val snapshot = _state.value
        val profileId = snapshot.activeProfileId ?: return
        val threadId = snapshot.selectedThreadId ?: return
        if (snapshot.queuedTurns.any { it.state == QueuedTurnState.Dispatching }) return
        val from = snapshot.queuedTurns.indexOfFirst { it.id == id }
        val to = (from + delta).coerceIn(0, snapshot.queuedTurns.lastIndex)
        if (from < 0 || from == to) return
        val reordered = snapshot.queuedTurns.toMutableList().apply { add(to, removeAt(from)) }
        viewModelScope.launch {
            runCatching { container.queuedTurnStore.reorder(profileId, threadId, reordered.map(QueuedTurn::id)) }
                .onSuccess {
                    if (_state.value.activeProfileId == profileId && _state.value.selectedThreadId == threadId) {
                        _state.update { it.copy(queuedTurns = reordered) }
                    }
                }
                .onFailure { error -> _state.update { it.copy(error = error.message ?: container.string(R.string.could_not_reorder_queued_messages)) } }
        }
    }

    fun guideQueuedTurnNow(id: String) {
        val snapshot = _state.value
        val item = snapshot.queuedTurns.firstOrNull { it.id == id } ?: return
        if (
            !ComposerSendMode.fromWire(item.collaborationMode).allowsGuidedFollowUp ||
            item.goalObjective != null
        ) {
            _state.update { it.copy(error = container.string(R.string.goal_plan_requires_new_turn)) }
            return
        }
        val activeTurnId = snapshot.activeTurnId
        if (
            item.state != QueuedTurnState.Waiting ||
            activeTurnId == null ||
            !snapshot.conversationConnected ||
            item.threadId != snapshot.selectedThreadId
        ) {
            _state.update { it.copy(error = container.string(R.string.no_active_reply_to_guide)) }
            return
        }
        viewModelScope.launch {
            try {
                container.queuedTurnStore.updateState(item.id, QueuedTurnState.Dispatching)
                _state.update {
                    it.copy(queuedTurns = it.queuedTurns.map { queued ->
                        if (queued.id == item.id) queued.copy(state = QueuedTurnState.Dispatching, lastError = null) else queued
                    })
                }
                requireNotNull(appServer).steerTurn(
                    item.threadId,
                    activeTurnId,
                    item.text,
                    item.id,
                    item.skills.map { SkillCapability(it.name, null, "queued", it.path, true) },
                    item.images,
                )
                container.queuedTurnStore.remove(item.id)
                _state.update {
                    it.copy(
                        queuedTurns = it.queuedTurns.filterNot { queued -> queued.id == item.id },
                        messages = it.messages + ConversationMessage(
                            item.id,
                            ConversationRole.User,
                            item.text.ifEmpty { "[${item.images.size} image attachment(s)]" },
                            attachments = item.images.map { image ->
                                ConversationAttachment(ConversationAttachmentKind.Image, url = image.dataUrl)
                            },
                        ),
                    )
                }
            } catch (failure: Throwable) {
                if (failure is CancellationException) throw failure
                val reason = failure.message?.takeIf(String::isNotBlank) ?: container.string(R.string.server_did_not_confirm_guidance)
                runCatching { container.queuedTurnStore.markNeedsConfirmation(item.id, reason) }
                _state.update {
                    it.copy(
                        queuedTurns = it.queuedTurns.map { queued ->
                            if (queued.id == item.id) queued.copy(
                                state = QueuedTurnState.NeedsConfirmation,
                                lastError = reason,
                            ) else queued
                        },
                        error = container.string(R.string.queued_guidance_confirmation_required, reason),
                    )
                }
            }
        }
    }

    private fun activateQueuedTurns(profileId: String) {
        viewModelScope.launch {
            runCatching { container.queuedTurnStore.recoverInterruptedDispatches(profileId) }
                .onFailure { error -> _state.update { it.copy(error = error.message ?: container.string(R.string.could_not_recover_queued_messages)) } }
            refreshQueuedTurns()
        }
    }

    private fun refreshQueuedTurns() {
        val snapshot = _state.value
        val profileId = snapshot.activeProfileId
        val threadId = snapshot.selectedThreadId
        if (profileId == null || threadId == null) {
            _state.update { it.copy(queuedTurns = emptyList(), queueLoading = false) }
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(queueLoading = true) }
            runCatching { container.queuedTurnStore.load(profileId, threadId) }
                .onSuccess { queued ->
                    if (_state.value.activeProfileId == profileId && _state.value.selectedThreadId == threadId) {
                        _state.update { it.copy(queuedTurns = queued, queueLoading = false) }
                    }
                }
                .onFailure { error -> _state.update { it.copy(queueLoading = false, error = error.message ?: container.string(R.string.could_not_load_queued_messages)) } }
        }
    }

    private fun flushNextQueuedTurn() {
        if (queuedDispatchJob?.isActive == true) return
        val snapshot = _state.value
        if (!snapshot.conversationConnected || TurnLifecycleProjection.isBusy(snapshot.activeTurnId, snapshot.awaitingTurnIdentity)) return
        // Queue order is authoritative. A failed first entry blocks later entries until the
        // user explicitly retries, deletes, edits, or reorders it.
        val next = QueuedTurnPolicy.nextDispatch(snapshot.queuedTurns) ?: return
        if (next.threadId != snapshot.selectedThreadId || next.profileId != snapshot.activeProfileId) return
        queuedDispatchJob = viewModelScope.launch {
            try {
                container.queuedTurnStore.updateState(next.id, QueuedTurnState.Dispatching)
                _state.update {
                    it.copy(
                        queuedTurns = it.queuedTurns.map { item ->
                            if (item.id == next.id) item.copy(state = QueuedTurnState.Dispatching) else item
                        },
                        messages = if (it.messages.any { message -> message.id == next.id }) {
                            it.messages
                        } else {
                            it.messages + next.conversationMessage()
                        },
                    )
                }
                val skills = next.skills.map { SkillCapability(it.name, null, "queued", it.path, true) }
                _state.update { it.copy(awaitingTurnIdentity = true) }
                val resolvedModel = ModelSelectionPolicy.resolve(
                    requestedModelId = next.model,
                    advertised = snapshot.modelOptions,
                    runtimeProvider = threadForId(next.threadId)?.runtimeProvider ?: activeRuntimeProvider,
                )
                val client = requireNotNull(appServer)
                val goal = next.goalObjective?.let { objective ->
                    client.setThreadGoal(
                        threadId = next.threadId,
                        objective = objective,
                        status = ThreadGoalStatus.Active,
                    )
                }
                if (goal != null) {
                    _state.update { it.copy(threadGoals = it.threadGoals + (next.threadId to goal)) }
                }
                val turnId = client.startTurn(
                    next.threadId,
                    next.cwd,
                    next.text,
                    next.id,
                    resolvedModel.id,
                    next.effort ?: resolvedModel.defaultReasoningEffort,
                    skills,
                    next.images,
                    PermissionMode.fromWire(next.permissionMode),
                    ComposerSendMode.fromWire(next.collaborationMode),
                )
                container.queuedTurnStore.remove(next.id)
                _state.update {
                    it.copy(
                        queuedTurns = it.queuedTurns.filterNot { item -> item.id == next.id },
                        activeTurnId = turnId ?: it.activeTurnId,
                        awaitingTurnIdentity = turnId == null && it.activeTurnId == null,
                    )
                }
            } catch (failure: Throwable) {
                if (failure is CancellationException) throw failure
                if (
                    _state.value.selectedThreadId == next.threadId &&
                    _state.value.activeTurnId != null
                ) {
                    runCatching { container.queuedTurnStore.remove(next.id) }
                    _state.update {
                        it.copy(
                            queuedTurns = it.queuedTurns.filterNot { item -> item.id == next.id },
                            awaitingTurnIdentity = false,
                        )
                    }
                } else {
                    val reason = failure.message?.takeIf(String::isNotBlank)
                        ?: container.string(R.string.server_did_not_confirm_queued_message)
                    runCatching { container.queuedTurnStore.markNeedsConfirmation(next.id, reason) }
                    _state.update {
                        it.copy(
                            queuedTurns = it.queuedTurns.map { item ->
                                if (item.id == next.id) item.copy(
                                    state = QueuedTurnState.NeedsConfirmation,
                                    lastError = reason,
                                ) else item
                            },
                            messages = it.messages.filterNot { message -> message.id == next.id },
                            awaitingTurnIdentity = false,
                            error = container.string(R.string.queued_message_confirmation_required, reason),
                        )
                    }
                }
            }
        }
    }

    private fun normalizedGoalObjective(mode: ComposerSendMode, text: String): String? =
        text.trim().takeIf { mode == ComposerSendMode.Goal && it.isNotEmpty() }

    fun selectModel(modelId: String?) {
        _state.update { current ->
            val option = current.modelOptions.firstOrNull { it.id == modelId }
            val effort = current.selectedReasoningEffort?.takeIf { option == null || option.supportedReasoningEfforts.isEmpty() || it in option.supportedReasoningEfforts }
                ?: option?.defaultReasoningEffort
            current.copy(selectedModelId = modelId, selectedReasoningEffort = effort)
        }
    }

    fun selectReasoningEffort(effort: String?) = _state.update { it.copy(selectedReasoningEffort = effort) }

    fun toggleSkill(path: String) {
        _state.update { current ->
            current.copy(selectedSkillPaths = if (path in current.selectedSkillPaths) current.selectedSkillPaths - path else current.selectedSkillPaths + path)
        }
        persistCurrentDraftImmediately(_state.value)
    }

    fun insertPluginMention(name: String) {
        setComposerText(CapabilityPickerPolicy.appendPluginMention(_state.value.composerText, name))
    }

    fun insertShortcut(shortcut: String) {
        setComposerText(CapabilityPickerPolicy.insertShortcut(_state.value.composerText, shortcut))
    }

    fun addManualSkill(name: String, path: String) {
        val skill = CapabilityPickerPolicy.manualSkill(name, path) ?: return
        _state.update { current ->
            val existing = current.skills.firstOrNull { it.path == skill.path }
            current.copy(
                skills = if (existing == null) current.skills + skill else current.skills,
                selectedSkillPaths = current.selectedSkillPaths + (existing?.path ?: skill.path),
            )
        }
        persistCurrentDraftImmediately(_state.value)
    }

    fun refreshComposerCapabilities() {
        val project = selectedProject() ?: return
        val client = appServer ?: return
        viewModelScope.launch {
            _state.update { it.copy(capabilitiesLoading = true) }
            val models = runCatching { client.modelOptions() }
            val skills = runCatching { client.skills(project.path) }
            val plugins = runCatching { client.installedPlugins(project.path) }
            if (selectedProject()?.id != project.id) return@launch
            _state.update { current ->
                val options = ModelSelectionPolicy.options(
                    advertised = models.getOrDefault(current.modelOptions),
                    runtimeProvider = activeRuntimeProvider,
                )
                val selectedModel = current.selectedModelId?.takeIf { id -> options.any { it.id == id } }
                    ?: options.firstOrNull { it.isDefault }?.id
                val selectedOption = options.firstOrNull { it.id == selectedModel }
                val effort = current.selectedReasoningEffort?.takeIf {
                    selectedOption == null || selectedOption.supportedReasoningEfforts.isEmpty() || it in selectedOption.supportedReasoningEfforts
                } ?: selectedOption?.defaultReasoningEffort
                val advertisedSkills = skills.getOrDefault(current.skills.filterNot { it.isManual })
                val manualSkills = current.skills.filter { it.isManual }
                val availableSkills = (advertisedSkills + manualSkills).distinctBy { it.path }
                current.copy(
                    capabilitiesLoading = false,
                    modelOptions = options,
                    selectedModelId = selectedModel,
                    selectedReasoningEffort = effort,
                    skills = availableSkills,
                    plugins = plugins.getOrDefault(current.plugins),
                    selectedSkillPaths = current.selectedSkillPaths.intersect(availableSkills.mapTo(mutableSetOf()) { it.path }),
                )
            }
        }
    }

    fun interruptTurn() {
        val snapshot = _state.value
        val threadId = snapshot.selectedThreadId ?: return
        val turnId = snapshot.activeTurnId ?: return
        viewModelScope.launch {
            runCatching { requireNotNull(appServer).interruptTurn(threadId, turnId) }
                .onFailure { error -> _state.update { it.copy(error = error.message ?: container.string(R.string.could_not_interrupt_turn)) } }
        }
    }

    fun browseDirectory(path: String = "") {
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        val normalized = path.trim()
        if (normalized.length > 4096) return showError(container.string(R.string.directory_path_too_long))
        viewModelScope.launch {
            _state.update { it.copy(workspaceLoading = true, error = null) }
            runCatching { container.apiClient.listDirectories(connection.profile.endpoint, token, normalized) }
                .onSuccess { listing -> _state.update { it.copy(workspaceLoading = false, directoryListing = listing) } }
                .onFailure { error -> _state.update { it.copy(workspaceLoading = false, error = error.message ?: container.string(R.string.could_not_browse_directory)) } }
        }
    }

    fun openWorkspace(path: String) {
        val normalized = path.trim()
        if (normalized.isEmpty() || normalized.length > 4096) return showError(container.string(R.string.valid_workspace_path_required))
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(workspaceLoading = true, error = null) }
            runCatching { container.apiClient.resolveWorkspace(connection.profile.endpoint, token, normalized) }
                .onSuccess { workspace ->
                    val project = AgentProject(workspace.id, workspace.name, workspace.path)
                    _state.update { current -> current.copy(
                        workspaceLoading = false,
                        projects = listOf(project) + current.projects.filterNot { it.id == project.id || it.path == project.path },
                        selectedProjectId = project.id,
                        directoryListing = null,
                    ) }
                    loadThreads(project.id)
                    refreshGit()
                    refreshInspectorCapabilities()
                }
                .onFailure { error -> _state.update { it.copy(workspaceLoading = false, error = error.message ?: container.string(R.string.could_not_open_workspace)) } }
        }
    }

    fun dismissDirectoryBrowser() = _state.update { it.copy(directoryListing = null, workspaceLoading = false) }

    fun refreshInspectorCapabilities() {
        val project = selectedProject() ?: return
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(commandActionLoading = true) }
            val actions = runCatching { container.apiClient.commandActions(connection.profile.endpoint, token, project.path) }
            val pullRequest = runCatching { container.apiClient.gitPullRequestStatus(connection.profile.endpoint, token, project.path) }
            val testFlight = runCatching { container.apiClient.gitTestFlightStatus(connection.profile.endpoint, token, project.path) }
            _state.update { current -> current.copy(
                commandActionLoading = false,
                commandActions = CommandActionPolicy.sanitizeAllowlist(actions.getOrNull()?.actions.orEmpty()),
                pullRequestStatus = pullRequest.getOrNull(),
                pullRequestUrl = pullRequest.getOrNull()?.url ?: current.pullRequestUrl,
                testFlightStatus = testFlight.getOrNull(),
            ) }
        }
    }

    fun refreshUsage() {
        val client = appServer ?: return
        viewModelScope.launch {
            _state.update { it.copy(usageLoading = true) }
            runCatching { client.rateLimits() }
                .onSuccess { usage -> _state.update { it.copy(usageLoading = false, rateLimits = usage) } }
                .onFailure { error -> _state.update { it.copy(usageLoading = false, error = error.message ?: container.string(R.string.could_not_load_account_usage)) } }
        }
    }

    fun runCommandAction(id: String, confirmed: Boolean) {
        val action = _state.value.commandActions.firstOrNull { it.id == id } ?: return showError(container.string(R.string.action_no_longer_available))
        if (action.requiresConfirmation && !confirmed) return showError(container.string(R.string.action_confirmation_required))
        val project = selectedProject() ?: return
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(commandActionLoading = true, commandActionResult = null, error = null) }
            runCatching { container.apiClient.runCommandAction(connection.profile.endpoint, token, project.path, action.id, confirmed) }
                .onSuccess { result ->
                    _state.update {
                        it.copy(
                            commandActionLoading = false,
                            commandActionResult = CommandActionPolicy.boundResult(result),
                        )
                    }
                }
                .onFailure { error -> _state.update { it.copy(commandActionLoading = false, error = error.message ?: container.string(R.string.action_failed)) } }
        }
    }

    fun clearCommandActionResult() = _state.update { it.copy(commandActionResult = null) }

    fun refreshGit() {
        val project = selectedProject() ?: return
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(gitLoading = true) }
            runCatching { container.apiClient.gitStatus(connection.profile.endpoint, token, project.path) }
                .onSuccess { status -> _state.update { it.copy(gitLoading = false, gitStatus = status) } }
                .onFailure { error -> _state.update { it.copy(gitLoading = false, error = error.message ?: container.string(R.string.could_not_load_git_status)) } }
        }
    }

    fun refreshWorktrees() {
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        val projectPath = selectedProject()?.path
        viewModelScope.launch {
            _state.update { it.copy(worktreeLoading = true, error = null) }
            val list = runCatching { container.apiClient.listWorktrees(connection.profile.endpoint, token) }
            val branches = projectPath?.let { path ->
                runCatching { container.apiClient.listWorktreeBranches(connection.profile.endpoint, token, path) }
            }
            _state.update { current -> current.copy(
                worktreeLoading = false,
                worktrees = list.getOrNull()?.worktrees ?: current.worktrees,
                worktreeBranches = branches?.getOrNull() ?: current.worktreeBranches,
                error = list.exceptionOrNull()?.message ?: branches?.exceptionOrNull()?.message,
            ) }
        }
    }

    fun refreshDiagnostics() {
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        val path = selectedProject()?.path
        viewModelScope.launch {
            _state.update { it.copy(diagnosticsLoading = true, error = null) }
            val doctor = runCatching { container.apiClient.doctor(connection.profile.endpoint, token) }
            val capabilities = runCatching { container.apiClient.capabilities(connection.profile.endpoint, token, path) }
            _state.update { current ->
                current.copy(
                    diagnosticsLoading = false,
                    doctorResults = doctor.getOrDefault(current.doctorResults),
                    mcpServers = capabilities.getOrNull()?.mcpServers ?: current.mcpServers,
                    error = doctor.exceptionOrNull()?.message ?: capabilities.exceptionOrNull()?.message,
                )
            }
        }
    }

    fun loadHistoryDiagnostics() {
        val snapshot = _state.value
        if (!snapshot.developerMode) return showError(container.string(R.string.developer_mode_required_for_history))
        val projectId = snapshot.selectedProjectId?.trim()?.takeIf(String::isNotEmpty)
            ?: return showError(container.string(R.string.select_project_for_history_diagnostics))
        val connection = snapshot.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(historyDiagnosticsLoading = true, historyDiagnostics = null, error = null) }
            runCatching {
                withTimeout(30_000L) {
                    container.apiClient.codexHistoryDiagnostics(
                        connection.profile.endpoint,
                        token,
                        projectId,
                        120,
                    )
                }.toString().take(500_000)
            }.onSuccess { payload -> _state.update { it.copy(historyDiagnosticsLoading = false, historyDiagnostics = payload) } }
                .onFailure { error -> _state.update { it.copy(historyDiagnosticsLoading = false, error = error.message ?: container.string(R.string.could_not_load_historical_diagnostics)) } }
        }
    }

    fun testConnection() {
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(connectionDiagnosticLoading = true, error = null) }
            val started = System.nanoTime()
            runCatching { withTimeout(10_000L) { container.apiClient.ready(connection.profile.endpoint, token) } }
                .onSuccess { health ->
                    val elapsed = (System.nanoTime() - started) / 1_000_000
                    val endpoint = connection.profile.endpoint
                    val host = runCatching { java.net.URI(endpoint).host.orEmpty() }.getOrDefault("")
                    val transport = when {
                        endpoint.startsWith("https://", true) -> "HTTPS"
                        host.endsWith(".ts.net", true) || host.startsWith("100.") -> container.string(R.string.transport_private_tailscale_http)
                        else -> container.string(R.string.transport_private_local_http)
                    }
                    val relay = runCatching { withTimeout(10_000L) { container.apiClient.relayDiagnostics(endpoint, token) } }.getOrNull()
                    val tailscale = runCatching { withTimeout(10_000L) { container.apiClient.tailscaleNetworkPath(endpoint, token) } }.getOrNull()
                    _state.update { it.copy(
                        connectionDiagnosticLoading = false,
                        connectionDiagnostic = ConnectionDiagnostic(endpoint, transport, elapsed, health.version, System.currentTimeMillis()),
                        relayDiagnostics = relay,
                        tailscaleNetworkPath = tailscale,
                    ) }
                }
                .onFailure { error -> _state.update { it.copy(connectionDiagnosticLoading = false, error = container.string(R.string.connection_test_failed, error.message.orEmpty())) } }
        }
    }

    fun createWorktree(name: String?, base: String?) {
        val project = selectedProject() ?: return
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(worktreeLoading = true, error = null) }
            runCatching {
                container.apiClient.createWorktree(
                    connection.profile.endpoint,
                    token,
                    project.path,
                    name?.trim()?.takeIf(String::isNotEmpty),
                    base?.trim()?.takeIf(String::isNotEmpty),
                )
                container.apiClient.listWorktrees(connection.profile.endpoint, token)
            }.onSuccess { response ->
                _state.update { it.copy(worktreeLoading = false, worktrees = response.worktrees) }
            }.onFailure { error ->
                _state.update { it.copy(worktreeLoading = false, error = error.message ?: container.string(R.string.could_not_create_worktree)) }
            }
        }
    }

    fun deleteWorktree(path: String) {
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(worktreeLoading = true, error = null) }
            runCatching { container.apiClient.deleteWorktree(connection.profile.endpoint, token, path) }
                .onSuccess { response ->
                    _state.update { it.copy(worktreeLoading = false, worktrees = response.worktrees) }
                    response.registryCleanupError?.let(::showError)
                }.onFailure { error ->
                    _state.update { it.copy(worktreeLoading = false, error = error.message ?: container.string(R.string.could_not_delete_worktree)) }
                }
        }
    }

    fun pruneWorktrees() {
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(worktreeLoading = true, error = null) }
            runCatching { container.apiClient.pruneWorktrees(connection.profile.endpoint, token) }
                .onSuccess { response ->
                    _state.update { it.copy(worktreeLoading = false, worktrees = response.worktrees) }
                    if (response.failedPaths.isNotEmpty()) showError(container.string(R.string.worktree_prune_partial_failure, response.failedPaths.keys.joinToString()))
                }.onFailure { error ->
                    _state.update { it.copy(worktreeLoading = false, error = error.message ?: container.string(R.string.could_not_prune_worktrees)) }
                }
        }
    }

    fun previewWorktreeCleanup() {
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(worktreeLoading = true, worktreeCleanupPreview = null, error = null) }
            runCatching { container.apiClient.previewWorktreeCleanup(connection.profile.endpoint, token) }
                .onSuccess { response -> _state.update { it.copy(worktreeLoading = false, worktreeCleanupPreview = response) } }
                .onFailure { error -> _state.update { it.copy(worktreeLoading = false, error = error.message ?: container.string(R.string.could_not_preview_cleanup)) } }
        }
    }

    fun executeWorktreeCleanup() {
        val preview = _state.value.worktreeCleanupPreview ?: return
        val planId = preview.planId?.takeIf(String::isNotBlank) ?: return showError(container.string(R.string.cleanup_plan_expired))
        if (preview.candidatePaths.isEmpty()) return dismissWorktreeCleanup()
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(worktreeLoading = true, worktreeCleanupPreview = null, error = null) }
            runCatching {
                val result = container.apiClient.executeWorktreeCleanup(
                    connection.profile.endpoint,
                    token,
                    preview.candidatePaths,
                    planId,
                )
                result to container.apiClient.listWorktrees(connection.profile.endpoint, token)
            }.onSuccess { (result, list) ->
                _state.update { it.copy(worktreeLoading = false, worktrees = list.worktrees) }
                result.error?.let(::showError)
            }.onFailure { error ->
                _state.update { it.copy(worktreeLoading = false, error = error.message ?: container.string(R.string.could_not_cleanup_worktrees)) }
            }
        }
    }

    fun dismissWorktreeCleanup() = _state.update { it.copy(worktreeCleanupPreview = null) }

    fun gitAction(action: GitActionKind, file: String) {
        val project = selectedProject() ?: return
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(gitLoading = true, error = null) }
            runCatching { container.apiClient.gitAction(connection.profile.endpoint, token, project.path, action, listOf(file)) }
                .onSuccess { status -> _state.update { it.copy(gitLoading = false, gitStatus = status) } }
                .onFailure { error -> _state.update { it.copy(gitLoading = false, error = error.message ?: container.string(R.string.git_action_failed)) } }
        }
    }

    fun gitPatchAction(action: GitActionKind, patch: String) {
        if (action !in setOf(GitActionKind.StagePatch, GitActionKind.UnstagePatch, GitActionKind.RevertPatch)) return
        if (patch.length !in 1..2_000_000 || !patch.startsWith("diff --git ") || !patch.contains("\n@@ ")) {
            return showError(container.string(R.string.invalid_git_hunk))
        }
        val project = selectedProject() ?: return
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(gitLoading = true, error = null) }
            runCatching { container.apiClient.gitPatchAction(connection.profile.endpoint, token, project.path, action, patch) }
                .onSuccess { status -> _state.update { it.copy(gitLoading = false, gitStatus = status) } }
                .onFailure { error -> _state.update { it.copy(gitLoading = false, error = error.message ?: container.string(R.string.git_hunk_action_failed)) } }
        }
    }

    fun gitCommit(message: String) {
        val normalized = message.trim()
        if (normalized.isEmpty() || normalized.length > 500) {
            return showError(container.string(R.string.commit_message_limit))
        }
        val project = selectedProject() ?: return
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(gitLoading = true, error = null) }
            runCatching { container.apiClient.gitCommit(connection.profile.endpoint, token, project.path, normalized) }
                .onSuccess { status -> _state.update { it.copy(gitLoading = false, gitStatus = status) } }
                .onFailure { error -> _state.update { it.copy(gitLoading = false, error = error.message ?: container.string(R.string.commit_failed)) } }
        }
    }

    fun gitPush() {
        val project = selectedProject() ?: return
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(gitLoading = true, error = null) }
            runCatching { container.apiClient.gitPush(connection.profile.endpoint, token, project.path) }
                .onSuccess { response -> _state.update { it.copy(gitLoading = false, gitStatus = response.status) } }
                .onFailure { error -> _state.update { it.copy(gitLoading = false, error = error.message ?: container.string(R.string.push_failed)) } }
        }
    }

    fun gitQuickPublish(message: String) {
        val normalized = message.trim()
        if (normalized.isEmpty() || normalized.length > 500) return showError(container.string(R.string.commit_message_limit))
        val project = selectedProject() ?: return
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(gitLoading = true, error = null) }
            runCatching { container.apiClient.gitQuickPublish(connection.profile.endpoint, token, project.path, normalized, confirmed = true) }
                .onSuccess { response -> _state.update { it.copy(gitLoading = false, gitStatus = response.status) } }
                .onFailure { error -> _state.update { it.copy(gitLoading = false, error = error.message ?: container.string(R.string.quick_publish_failed)) } }
        }
    }

    fun createPullRequest(title: String, body: String, draft: Boolean) {
        val normalizedTitle = title.trim()
        if (normalizedTitle.isEmpty() || normalizedTitle.length > 256 || body.length > 64_000) return showError(container.string(R.string.valid_pull_request_required))
        val project = selectedProject() ?: return
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(gitLoading = true, error = null) }
            runCatching { container.apiClient.gitCreatePullRequest(connection.profile.endpoint, token, project.path, normalizedTitle, body.trim(), draft) }
                .onSuccess { response ->
                    _state.update { it.copy(gitLoading = false, pullRequestUrl = response.url) }
                    refreshInspectorCapabilities()
                }
                .onFailure { error -> _state.update { it.copy(gitLoading = false, error = error.message ?: container.string(R.string.could_not_create_pull_request)) } }
        }
    }

    fun runTestFlight(whatToTest: String) {
        val normalized = whatToTest.trim()
        if (normalized.isEmpty() || normalized.length > 4_000) return showError(container.string(R.string.test_verification_required))
        val status = _state.value.testFlightStatus ?: return
        if (!status.capability.available || status.job?.state == "running") return
        val project = selectedProject() ?: return
        val connection = _state.value.connected ?: return
        val token = activeToken ?: return
        viewModelScope.launch {
            _state.update { it.copy(gitLoading = true, error = null) }
            runCatching { container.apiClient.gitTestFlightRun(connection.profile.endpoint, token, project.path, normalized, confirmed = true) }
                .onSuccess { result -> _state.update { it.copy(gitLoading = false, testFlightStatus = result) } }
                .onFailure { error -> _state.update { it.copy(gitLoading = false, error = error.message ?: container.string(R.string.could_not_start_testflight_publish)) } }
        }
    }

    fun decideApproval(decision: String) {
        val threadId = _state.value.selectedThreadId ?: return
        val request = _state.value.pendingApprovals[threadId] ?: return
        if (_state.value.respondingToRequest || !ApprovalDecisionPolicy.canSubmitDecision(request, decision)) return
        _state.update { it.copy(respondingToRequest = true) }
        viewModelScope.launch {
            runCatching {
                requireNotNull(appServer).respond(request.requestId, AppServerProjection.approvalResponse(request, decision))
            }.onSuccess {
                _state.update {
                    it.copy(
                        respondingToRequest = false,
                        pendingApprovals = if (it.pendingApprovals[threadId]?.id == request.id) {
                            it.pendingApprovals - threadId
                        } else {
                            it.pendingApprovals
                        },
                    )
                }
            }.onFailure { error ->
                _state.update {
                    it.copy(
                        respondingToRequest = false,
                        error = error.message ?: container.string(R.string.could_not_send_approval),
                    )
                }
            }
        }
    }

    fun submitUserInput(answers: Map<String, List<String>>) {
        val threadId = _state.value.selectedThreadId ?: return
        val request = _state.value.pendingUserInputs[threadId] ?: return
        _state.update { it.copy(respondingToRequest = true) }
        viewModelScope.launch {
            runCatching {
                requireNotNull(appServer).respond(request.requestId, AppServerProjection.userInputResponse(request, answers))
            }.onSuccess {
                _state.update {
                    it.copy(
                        respondingToRequest = false,
                        pendingUserInputs = if (it.pendingUserInputs[threadId]?.id == request.id) {
                            it.pendingUserInputs - threadId
                        } else {
                            it.pendingUserInputs
                        },
                    )
                }
            }.onFailure { error ->
                _state.update {
                    it.copy(
                        respondingToRequest = false,
                        error = error.message ?: container.string(R.string.could_not_submit_answers),
                    )
                }
            }
        }
    }
    fun clearError() = _state.update { it.copy(error = null) }
    fun showError(message: String) = _state.update { it.copy(error = message) }

    fun switchProfile(profileId: String) {
        if (profileId == _state.value.activeProfileId && _state.value.connected != null) return
        val profile = _state.value.profiles.firstOrNull { it.id == profileId } ?: return
        viewModelScope.launch {
            var candidate: AppServerClient? = null
            _state.update { it.copy(loading = true, error = null) }
            try {
                withTimeout(10_000L) {
                val token = withContext(Dispatchers.IO) { container.credentialStore.read(profile.id) }
                    ?.takeIf(String::isNotBlank) ?: error(container.string(R.string.saved_credentials_unavailable))
                val health = container.apiClient.ready(profile.endpoint, token)
                val projects = container.apiClient.projects(profile.endpoint, token)
                val config = runCatching { container.apiClient.appServerConfig(profile.endpoint, token) }.getOrNull()
                val runtimeProviders = RuntimeRoutingPolicy.availableProviders(config?.channels.orEmpty())
                val nextClient = container.newAppServerClient().also { candidate = it }
                nextClient.connect(profile.endpoint, token, runtimeProvider = "codex")
                val firstProject = projects.firstOrNull()
                val codexPage = firstProject?.let { nextClient.listThreads(it.path) }
                val claudePage = if (firstProject != null && "claude" in runtimeProviders) {
                    runCatching {
                        val temporary = container.newAppServerClient()
                        try {
                            temporary.connect(profile.endpoint, token, runtimeProvider = "claude")
                            temporary.listThreads(firstProject.path)
                        } finally { temporary.close() }
                    }.getOrNull()
                } else null
                val threads = (codexPage?.threads.orEmpty() + claudePage?.threads.orEmpty())
                    .distinctBy(AgentThread::id)
                    .sortedByDescending { it.updatedAtEpochSeconds ?: it.createdAtEpochSeconds ?: 0 }
                val refreshed = profile.copy(lastConnectedAtEpochMillis = System.currentTimeMillis())
                container.profileStore.upsert(refreshed)
                container.profileStore.setActive(refreshed.id)

                reconnectJob?.cancel()
                queuedDispatchJob?.cancel()
                if (_state.value.voiceRecording) container.voiceRecorder.cancel()
                appServerEventsJob?.cancel()
                appServerStatusJob?.cancel()
                appServer?.close()
                appServer = nextClient
                activeRuntimeProvider = "codex"
                activeToken = token
                candidate = null
                bindAppServer(nextClient)
                invalidateSessionSearch()
                _state.update { current -> current.copy(
                    loading = false,
                    endpoint = refreshed.endpoint,
                    token = "",
                    displayName = refreshed.displayName,
                    connected = ConnectedAgent(refreshed, health.version, projects),
                    projects = projects,
                    selectedProjectId = firstProject?.id,
                    threads = threads,
                    selectedThreadId = null,
                    messages = emptyList(),
                    conversationConnected = true,
                    credentialsInvalid = false,
                    gitStatus = null,
                    activeProfileId = refreshed.id,
                    profiles = (current.profiles.filterNot { it.id == refreshed.id } + refreshed)
                        .sortedByDescending { it.lastConnectedAtEpochMillis ?: it.createdAtEpochMillis },
                    sessionSearchQuery = "",
                    sessionSearchResults = emptyList(),
                    sessionSearchCursor = null,
                    sessionSearchCursors = emptyMap(),
                    threadCursor = listOfNotNull(codexPage?.nextCursor, claudePage?.nextCursor).firstOrNull(),
                    threadCursors = buildMap {
                        codexPage?.nextCursor?.let { put("codex", it) }
                        claudePage?.nextCursor?.let { put("claude", it) }
                    },
                    availableRuntimeProviders = runtimeProviders,
                    newSessionRuntimeProvider = "codex",
                ) }
                firstProject?.let { loadThreads(it.id) }
                activateQueuedTurns(refreshed.id)
                refreshPinnedThreads()
                refreshSessionReminders()
                refreshGit()
                refreshInspectorCapabilities()
                refreshComposerCapabilities()
                refreshUsage()
                openPendingNotificationRoute()
                }
            } catch (failure: Throwable) {
                candidate?.close()
                if (failure is TimeoutCancellationException) {
                    val timeout = container.string(R.string.saved_mac_timeout)
                    val message = privateEndpointVpnFailure(profile.endpoint, timeout) ?: timeout
                    _state.update { it.copy(loading = false, error = message) }
                    return@launch
                }
                if (failure is CancellationException) throw failure
                val detail = failure.message ?: container.string(R.string.could_not_switch_mac)
                val message = privateEndpointVpnFailure(profile.endpoint, detail) ?: detail
                _state.update { it.copy(loading = false, error = message) }
            }
        }
    }

    fun deleteProfile(profileId: String) {
        if (profileId == _state.value.activeProfileId) {
            showError(container.string(R.string.switch_mac_before_forgetting))
            return
        }
        viewModelScope.launch {
            runCatching {
                // Credential deletion is the commit point: metadata stays intact if secure deletion fails.
                withContext(Dispatchers.IO) { container.credentialStore.delete(profileId) }
                container.profileStore.remove(profileId)
                container.pinnedThreadStore.removeProfile(profileId)
                container.sessionReminderStore.removeProfile(profileId).forEach { reminder ->
                    container.sessionReminderScheduler.cancel(profileId, reminder.projectId, reminder.threadId)
                }
            }.onSuccess {
                _state.update { it.copy(profiles = it.profiles.filterNot { profile -> profile.id == profileId }) }
            }.onFailure { error ->
                _state.update { it.copy(error = error.message ?: container.string(R.string.could_not_forget_mac)) }
            }
        }
    }

    fun renameProfile(profileId: String, displayName: String) {
        val normalized = displayName.trim()
        if (normalized.isEmpty() || normalized.length > 80) {
            showError(container.string(R.string.mac_name_length))
            return
        }
        val profile = _state.value.profiles.firstOrNull { it.id == profileId } ?: return
        viewModelScope.launch {
            val renamed = profile.copy(displayName = normalized)
            runCatching { container.profileStore.upsert(renamed) }
                .onSuccess { _state.update { current -> current.copy(
                    profiles = current.profiles.map { if (it.id == profileId) renamed else it },
                    connected = current.connected?.let { if (it.profile.id == profileId) it.copy(profile = renamed) else it },
                    displayName = if (current.activeProfileId == profileId) normalized else current.displayName,
                ) } }
                .onFailure { error -> _state.update { it.copy(error = error.message ?: container.string(R.string.could_not_rename_mac)) } }
        }
    }

    fun prepareNewProfile() {
        reconnectJob?.cancel()
        queuedDispatchJob?.cancel()
        appServerEventsJob?.cancel()
        appServerStatusJob?.cancel()
        appServer?.close()
        container.voiceRecorder.close()
        container.deviceSpeechTranscriber.close()
        appServer = null
        activeToken = null
        invalidateSessionSearch()
        _state.update {
            MainUiState(
                profiles = it.profiles,
                activeProfileId = it.activeProfileId,
                networkAvailable = it.networkAvailable,
                displayName = container.string(R.string.default_mac_name),
                themeMode = it.themeMode,
                themePreset = it.themePreset,
                dynamicColor = it.dynamicColor,
                uiFontPreset = it.uiFontPreset,
                codeFontPreset = it.codeFontPreset,
                fontScale = it.fontScale,
                keepScreenOn = it.keepScreenOn,
                permissionMode = it.permissionMode,
                voiceMode = it.voiceMode,
                deviceSpeechAvailable = it.deviceSpeechAvailable,
                languageTag = it.languageTag,
                developerMode = it.developerMode,
            )
        }
    }

    fun acceptDeepLink(uri: Uri?) {
        if (uri == null) return
        if (uri.scheme != "mimiremote") {
            showError(container.string(R.string.invalid_pairing_qr))
            return
        }
        if (uri.host == "open") {
                val route = SessionNotificationRoute.parse(uri)
                if (route == null) {
                    showError(container.string(R.string.notification_route_incomplete))
                } else {
                    pendingNotificationRoute = route
                    openPendingNotificationRoute()
                }
            return
        }
        when (val assessment = PairingLinkPolicy.assess(uri)) {
            is PairingLinkAssessment.SignedTicket -> claimPairing(assessment)
            is PairingLinkAssessment.LegacyConnection -> {
                _state.update { it.copy(pendingPairingLink = uri, error = null) }
            }
            is PairingLinkAssessment.Rejected -> showPairingLinkError(assessment)
        }
    }

    fun confirmLegacyConnectionLink() {
        val uri = _state.value.pendingPairingLink ?: return
        if (uri.host != "connect") return dismissLegacyConnectionLink()
        when (val assessment = PairingLinkPolicy.assess(uri)) {
            is PairingLinkAssessment.LegacyConnection -> {
                _state.update {
                    it.copy(
                        endpoint = assessment.endpoint,
                        token = assessment.token,
                        pendingPairingLink = null,
                        error = null,
                    )
                }
            }
            is PairingLinkAssessment.Rejected -> {
                _state.update { it.copy(pendingPairingLink = null) }
                showPairingLinkError(assessment)
            }
            is PairingLinkAssessment.SignedTicket -> dismissLegacyConnectionLink()
        }
    }

    fun dismissLegacyConnectionLink() = _state.update { it.copy(pendingPairingLink = null) }

    fun connect() = connectWithTimeout(45_000L)

    private fun connectWithTimeout(timeoutMillis: Long) {
        val snapshot = _state.value
        if (snapshot.token.isBlank()) {
            _state.update { it.copy(error = container.string(R.string.token_required)) }
            return
        }
        viewModelScope.launch {
            var candidateAppServer: AppServerClient? = null
            var connectionStage = container.string(R.string.connection_stage_validate_address)
            _state.update { it.copy(loading = true, error = null) }
            try {
                withTimeout(timeoutMillis) {
                // Host resolution can touch DNS, so endpoint assessment stays off the main thread.
                val assessment = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    EndpointPolicy.assess(snapshot.endpoint)
                }
                if (assessment is EndpointAssessment.Rejected) {
                    _state.update { it.copy(loading = false, error = localizedEndpointRejection(assessment.reason)) }
                    return@withTimeout
                }
                val endpoint = (assessment as EndpointAssessment.Allowed).normalizedEndpoint
                connectionStage = container.string(R.string.connection_stage_check_readiness)
                val health = container.apiClient.ready(endpoint, snapshot.token.trim())
                connectionStage = container.string(R.string.connection_stage_load_projects)
                val projects = container.apiClient.projects(endpoint, snapshot.token.trim())
                connectionStage = container.string(R.string.connection_stage_load_config)
                val appServerConfig = runCatching { container.apiClient.appServerConfig(endpoint, snapshot.token.trim()) }.getOrNull()
                val runtimeProviders = RuntimeRoutingPolicy.availableProviders(appServerConfig?.channels.orEmpty())
                val nextAppServer = container.newAppServerClient()
                candidateAppServer = nextAppServer
                connectionStage = container.string(R.string.connection_stage_open_codex)
                nextAppServer.connect(endpoint, snapshot.token.trim(), runtimeProvider = "codex")
                val firstProject = projects.firstOrNull()
                connectionStage = container.string(R.string.connection_stage_load_codex_sessions)
                val threadPage = firstProject?.let { nextAppServer.listThreads(it.path) }
                val claudePage = if (firstProject != null && "claude" in runtimeProviders) {
                    runCatching {
                        val temporary = container.newAppServerClient()
                        try {
                            connectionStage = container.string(R.string.connection_stage_open_claude)
                            temporary.connect(endpoint, snapshot.token.trim(), runtimeProvider = "claude")
                            connectionStage = container.string(R.string.connection_stage_load_claude_sessions)
                            temporary.listThreads(firstProject.path)
                        } finally { temporary.close() }
                    }.getOrNull()
                } else null
                connectionStage = container.string(R.string.connection_stage_prepare_profile)
                val threads = (threadPage?.threads.orEmpty() + claudePage?.threads.orEmpty())
                    .distinctBy(AgentThread::id)
                    .sortedByDescending { it.updatedAtEpochSeconds ?: it.createdAtEpochSeconds ?: 0 }
                val now = System.currentTimeMillis()
                val existing = snapshot.profiles.firstOrNull { it.endpoint == endpoint }
                val profile = ConnectionProfile(
                    id = UUID.nameUUIDFromBytes(endpoint.toByteArray()).toString(),
                    displayName = snapshot.displayName.trim().ifEmpty { container.string(R.string.default_mac_name) },
                    endpoint = endpoint,
                    createdAtEpochMillis = existing?.createdAtEpochMillis ?: now,
                    lastConnectedAtEpochMillis = now,
                )
                connectionStage = container.string(R.string.connection_stage_save_credentials)
                container.credentialStore.write(profile.id, snapshot.token.trim())
                connectionStage = container.string(R.string.connection_stage_save_profile)
                container.profileStore.upsert(profile)
                container.profileStore.setActive(profile.id)
                queuedDispatchJob?.cancel()
                appServerEventsJob?.cancel()
                appServerStatusJob?.cancel()
                appServer?.close()
                appServer = nextAppServer
                activeRuntimeProvider = "codex"
                activeToken = snapshot.token.trim()
                candidateAppServer = null
                bindAppServer(nextAppServer)
                _state.update {
                    it.copy(
                        loading = false,
                        endpoint = endpoint,
                        token = "",
                        connected = ConnectedAgent(profile, health.version, projects),
                        projects = projects,
                        selectedProjectId = firstProject?.id,
                        threads = threads,
                        selectedThreadId = null,
                        conversationConnected = true,
                        credentialsInvalid = false,
                        activeProfileId = profile.id,
                        threadCursor = listOfNotNull(threadPage?.nextCursor, claudePage?.nextCursor).firstOrNull(),
                        threadCursors = buildMap {
                            threadPage?.nextCursor?.let { put("codex", it) }
                            claudePage?.nextCursor?.let { put("claude", it) }
                        },
                        profiles = (it.profiles.filterNot { item -> item.id == profile.id } + profile)
                            .sortedByDescending { item -> item.lastConnectedAtEpochMillis ?: item.createdAtEpochMillis },
                        availableRuntimeProviders = runtimeProviders,
                        newSessionRuntimeProvider = "codex",
                    )
                }
                activateQueuedTurns(profile.id)
                refreshPinnedThreads()
                refreshSessionReminders()
                refreshGit()
                refreshInspectorCapabilities()
                refreshComposerCapabilities()
                refreshUsage()
                openPendingNotificationRoute()
                }
            } catch (error: Throwable) {
                candidateAppServer?.close()
                if (error is TimeoutCancellationException) {
                    val timeout = container.string(
                        R.string.connection_ready_timeout,
                        connectionStage,
                        timeoutMillis / 1_000,
                    )
                    val message = privateEndpointVpnFailure(snapshot.endpoint, timeout) ?: timeout
                    _state.update {
                        it.copy(
                            loading = false,
                            error = message,
                        )
                    }
                    return@launch
                }
                if (error is CancellationException) throw error
                val detail = error.message?.trim().orEmpty()
                val type = error::class.simpleName?.takeIf(String::isNotBlank) ?: container.string(R.string.unknown_error)
                val message = if (detail.isNotEmpty()) {
                    container.string(R.string.connection_failed_with_detail, connectionStage, detail)
                } else {
                    container.string(R.string.connection_failed_with_type, connectionStage, type)
                }
                val diagnosed = privateEndpointVpnFailure(snapshot.endpoint, message) ?: message
                _state.update { it.copy(loading = false, error = diagnosed) }
            }
        }
    }

    private fun reduceAppServerStatus(status: AppServerStatus) {
        appendDiagnosticLog(DiagnosticLogPolicy.transport(status::class.simpleName.orEmpty()))
        when (status) {
            AppServerStatus.Connected -> {
                _state.update { it.copy(conversationConnected = true, credentialsInvalid = false) }
                flushNextQueuedTurn()
            }
            AppServerStatus.Connecting -> _state.update { it.copy(conversationConnected = false) }
            AppServerStatus.Suspended -> _state.update { it.copy(conversationConnected = false) }
            is AppServerStatus.Disconnected -> {
                _state.update {
                    it.copy(
                        conversationConnected = false,
                        credentialsInvalid = status.credentialsInvalid,
                        error = if (status.credentialsInvalid) container.string(R.string.access_token_invalid) else it.error,
                    )
                }
                if (!status.credentialsInvalid) scheduleReconnect()
            }
        }
    }

    private fun scheduleReconnect() {
        val snapshot = _state.value
        if (!appForeground || !snapshot.networkAvailable || snapshot.credentialsInvalid || snapshot.connected == null || activeToken.isNullOrBlank()) return
        if (snapshot.conversationConnected || reconnectJob?.isActive == true) return
        reconnectJob = viewModelScope.launch {
            var backoffMillis = 1_000L
            while (isActive && appForeground && _state.value.networkAvailable && !_state.value.credentialsInvalid) {
                val client = appServer ?: return@launch
                val profile = _state.value.connected?.profile ?: return@launch
                val token = activeToken ?: return@launch
                val thread = _state.value.threads.firstOrNull { it.id == _state.value.selectedThreadId }
                val result = runCatching {
                    withTimeout(10_000L) {
                        val runtime = thread?.runtimeProvider ?: activeRuntimeProvider
                        client.connect(profile.endpoint, token, thread?.id, runtime)
                        if (thread != null) client.resumeThread(thread.id, thread.cwd, _state.value.permissionMode)
                    }
                }
                if (result.isSuccess) {
                    _state.update { it.copy(conversationConnected = true) }
                    return@launch
                }
                if (_state.value.credentialsInvalid) return@launch
                val jittered = (backoffMillis * kotlin.random.Random.nextDouble(0.8, 1.2)).toLong()
                delay(jittered)
                backoffMillis = (backoffMillis * 2).coerceAtMost(30_000L)
            }
        }
    }

    private fun privateEndpointVpnFailure(endpoint: String, detail: String): String? {
        val assessment = EndpointPolicy.assess(endpoint) as? EndpointAssessment.Allowed ?: return null
        return container.string(R.string.private_endpoint_vpn_failure, detail)
            .takeIf { assessment.cleartext && container.networkMonitor.isVpnActive() }
    }

    private fun localizedEndpointRejection(reason: String): String = when (reason) {
        "Connection address is required" -> container.string(R.string.endpoint_required)
        "Connection address is invalid" -> container.string(R.string.endpoint_invalid)
        "Only HTTP and HTTPS endpoints are supported" -> container.string(R.string.endpoint_scheme_unsupported)
        "Connection host is missing" -> container.string(R.string.endpoint_host_missing)
        "Credentials, query parameters and fragments are not allowed" -> container.string(R.string.endpoint_extras_not_allowed)
        "Connection address must not contain a path" -> container.string(R.string.endpoint_path_not_allowed)
        "Connection port is invalid" -> container.string(R.string.endpoint_port_invalid)
        "Public HTTP endpoints are blocked; use HTTPS" -> container.string(R.string.endpoint_public_http_blocked)
        else -> reason
    }

    private fun loadThreads(projectId: String) {
        val project = _state.value.projects.firstOrNull { it.id == projectId } ?: return
        threadListGeneration += 1
        val generation = threadListGeneration
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            runCatching {
                val results = _state.value.availableRuntimeProviders.associateWith { runtime ->
                    runCatching { runtimeThreads(runtime, project.path) }
                }
                val pages = results.mapNotNull { (runtime, result) -> result.getOrNull()?.let { runtime to it } }.toMap()
                if (pages.isEmpty()) throw requireNotNull(results.values.firstNotNullOfOrNull { it.exceptionOrNull() })
                pages
            }
                .onSuccess { pages ->
                    if (!ThreadListPolicy.isCurrent(generation, threadListGeneration, projectId, _state.value.selectedProjectId)) {
                        return@onSuccess
                    }
                    _state.update { current ->
                        val projection = ThreadListPolicy.initial(pages)
                        current.copy(
                            loading = false,
                            threads = contextualizeThreads(
                                incoming = projection.threads,
                                existing = current.threads,
                            ).sortedByDescending { it.updatedAtEpochSeconds ?: it.createdAtEpochSeconds ?: 0 },
                            threadCursor = projection.cursors.values.firstOrNull(),
                            threadCursors = projection.cursors,
                        )
                    }
                }
                .onFailure { error ->
                    if (ThreadListPolicy.isCurrent(generation, threadListGeneration, projectId, _state.value.selectedProjectId)) {
                        _state.update { it.copy(loading = false, error = error.message ?: container.string(R.string.could_not_load_sessions)) }
                    }
                }
        }
    }

    private fun selectedProject(): AgentProject? =
        _state.value.projects.firstOrNull { it.id == _state.value.selectedProjectId }

    private fun threadForId(threadId: String): AgentThread? =
        _state.value.threads.firstOrNull { it.id == threadId }
            ?: _state.value.sessionSearchResults.firstOrNull { it.thread.id == threadId }?.thread

    private fun openPendingNotificationRoute() {
        val route = pendingNotificationRoute ?: return
        val connection = _state.value.connected ?: return
        val profileId = route.profileId
        val projectId = route.projectId
        val threadId = route.threadId
        if (profileId != connection.profile.id) {
            pendingNotificationRoute = null
            val name = _state.value.profiles.firstOrNull { it.id == profileId }?.displayName ?: container.string(R.string.another_mac)
            showError(container.string(R.string.notification_wrong_mac, name))
            return
        }
        val project = _state.value.projects.firstOrNull { it.id == projectId }
        if (project == null) {
            pendingNotificationRoute = null
            showError(container.string(R.string.notification_project_unavailable))
            return
        }
        pendingNotificationRoute = null
        viewModelScope.launch {
            _state.update { it.copy(loading = true, selectedProjectId = project.id, error = null) }
            val collected = mutableListOf<AgentThread>()
            var successfulRuntime = false
            for (runtime in _state.value.availableRuntimeProviders) {
                var runtimeCursor: String? = null
                for (pageIndex in 0 until 5) {
                    val page = runCatching { runtimeThreads(runtime, project.path, runtimeCursor) }.getOrNull() ?: break
                    successfulRuntime = true
                    collected += page.threads
                    if (collected.any { it.id == threadId } || page.nextCursor == null || page.nextCursor == runtimeCursor) break
                    runtimeCursor = page.nextCursor
                }
                if (collected.any { it.id == threadId }) break
            }
            if (!successfulRuntime) {
                _state.update { it.copy(loading = false, error = container.string(R.string.no_runtime_available)) }
                return@launch
            }
            val target = collected.firstOrNull { it.id == threadId }
            if (target == null) {
                _state.update { it.copy(loading = false, threads = collected.distinctBy(AgentThread::id), error = container.string(R.string.notification_session_unavailable)) }
            } else {
                _state.update { it.copy(loading = false, threads = collected.distinctBy(AgentThread::id), threadCursor = null, threadCursors = emptyMap()) }
                selectThread(target.id)
            }
        }
    }

    private fun postRuntimeNotification(kind: RuntimeNotificationKind, title: String, body: String, threadId: String?) {
        if (appForeground || threadId == null) return
        val snapshot = _state.value
        val profileId = snapshot.activeProfileId ?: return
        val projectId = snapshot.projects.firstOrNull { project ->
            snapshot.threads.firstOrNull { it.id == threadId }?.cwd == project.path
        }?.id ?: snapshot.selectedProjectId ?: return
        container.notificationCenter.post(kind, title, body, profileId, projectId, threadId)
    }

    private fun bindAppServer(client: AppServerClient) {
        appServerEventsJob = viewModelScope.launch { client.events.collect(::reduceAppServerEvent) }
        appServerStatusJob = viewModelScope.launch { client.statuses.collect(::reduceAppServerStatus) }
    }

    private suspend fun ensureRuntime(runtimeProvider: String, threadId: String? = null): AppServerClient {
        val normalized = RuntimeRoutingPolicy.normalize(runtimeProvider)
        appServer?.takeIf { activeRuntimeProvider == normalized }?.let { return it }
        require(normalized in _state.value.availableRuntimeProviders) { container.string(R.string.runtime_unavailable_on_mac, normalized) }
        val connection = _state.value.connected ?: error(container.string(R.string.mac_not_connected))
        val token = activeToken ?: error(container.string(R.string.connection_credentials_unavailable))
        val candidate = container.newAppServerClient()
        try {
            candidate.connect(connection.profile.endpoint, token, threadId, normalized)
        } catch (error: Throwable) {
            candidate.close()
            throw error
        }
        reconnectJob?.cancel()
        appServerEventsJob?.cancel()
        appServerStatusJob?.cancel()
        appServer?.close()
        appServer = candidate
        activeRuntimeProvider = normalized
        bindAppServer(candidate)
        _state.update { it.copy(conversationConnected = true) }
        return candidate
    }

    private suspend fun runtimeThreads(runtimeProvider: String, cwd: String, cursor: String? = null): com.gaixianggeng.mimi.core.model.ThreadPage {
        if (activeRuntimeProvider == runtimeProvider) return requireNotNull(appServer).listThreads(cwd, cursor)
        val connection = _state.value.connected ?: error(container.string(R.string.mac_not_connected))
        val token = activeToken ?: error(container.string(R.string.connection_credentials_unavailable))
        val temporary = container.newAppServerClient()
        return try {
            temporary.connect(connection.profile.endpoint, token, runtimeProvider = runtimeProvider)
            temporary.listThreads(cwd, cursor)
        } finally { temporary.close() }
    }

    private suspend fun runtimeSearch(runtimeProvider: String, query: String, cursor: String? = null): com.gaixianggeng.mimi.core.model.ThreadSearchPage {
        if (activeRuntimeProvider == runtimeProvider) return requireNotNull(appServer).searchThreads(query, cursor)
        val connection = _state.value.connected ?: error(container.string(R.string.mac_not_connected))
        val token = activeToken ?: error(container.string(R.string.connection_credentials_unavailable))
        val temporary = container.newAppServerClient()
        return try {
            temporary.connect(connection.profile.endpoint, token, runtimeProvider = runtimeProvider)
            temporary.searchThreads(query, cursor)
        } finally { temporary.close() }
    }

    private fun invalidateSessionSearch() {
        sessionSearchGeneration += 1
        sessionSearchJob?.cancel()
        sessionSearchJob = null
    }

    private fun reduceAppServerEvent(event: AppServerEvent) {
        if (!event.method.endsWith("/delta")) appendDiagnosticLog(DiagnosticLogPolicy.event(event.method))
        TurnLifecycleProjection.activeTurnFromEvent(event)?.let { identity ->
            updateThreadContext(identity.threadId, SessionContextProjection.statusUpdate(identity.threadId, "running"))
            if (identity.threadId == _state.value.selectedThreadId) {
                _state.update {
                    it.copy(
                        activeTurnId = identity.turnId,
                        awaitingTurnIdentity = false,
                    )
                }
            }
        }
        AppServerProjection.userInput(event)?.let { request ->
            _state.update { it.copy(pendingUserInputs = it.pendingUserInputs + (request.threadId to request)) }
            postRuntimeNotification(
                RuntimeNotificationKind.Approval,
                container.string(R.string.notification_needs_input),
                request.questions.firstOrNull()?.question ?: container.string(R.string.notification_open_session_to_continue),
                request.threadId,
            )
            return
        }
        AppServerProjection.approval(event)?.let { request ->
            val threadId = request.threadId ?: _state.value.selectedThreadId ?: return
            _state.update { it.copy(pendingApprovals = it.pendingApprovals + (threadId to request)) }
            postRuntimeNotification(RuntimeNotificationKind.Approval, container.string(R.string.notification_needs_approval), request.title, threadId)
            return
        }
        when (event.method) {
            "account/rateLimits/updated" -> {
                val limits = AppServerProjection.rateLimitSummary(event.params) ?: return
                _state.update { it.copy(rateLimits = limits) }
            }
            "thread/goal/updated" -> {
                val goal = AppServerProjection.threadGoal(event.params) ?: return
                _state.update { it.copy(threadGoals = it.threadGoals + (goal.threadId to goal)) }
            }
            "thread/goal/cleared" -> {
                val threadId = event.params.firstString("threadId", "thread_id") ?: return
                _state.update { it.copy(threadGoals = it.threadGoals - threadId) }
            }
            "turn/started" -> {
                val threadId = event.params.firstString("threadId", "thread_id") ?: return
                updateThreadContext(threadId, SessionContextProjection.statusUpdate(threadId, "running"))
                if (threadId != _state.value.selectedThreadId) return
                val turnId = TurnLifecycleProjection.activeTurnFromEvent(event)?.turnId
                _state.update {
                    it.copy(
                        activeTurnId = turnId ?: it.activeTurnId,
                        awaitingTurnIdentity = turnId == null && it.activeTurnId == null,
                    )
                }
            }
            "turn/plan/updated" -> {
                val threadId = event.params.firstString("threadId", "thread_id") ?: return
                if (threadId != _state.value.selectedThreadId) return
                val text = AppServerProjection.planMarkdown(event.params) ?: return
                val turnId = event.params.firstString("turnId", "turn_id") ?: "current"
                upsertConversationMessage(
                    ConversationMessage(
                        id = "plan-$turnId",
                        role = ConversationRole.Activity,
                        text = text,
                        streaming = true,
                        turnId = turnId,
                        itemId = "plan-$turnId",
                        activity = ConversationActivity(
                            category = ConversationActivityCategory.Plan,
                            title = container.string(R.string.activity_plan),
                            subtitle = text,
                            status = "inProgress",
                        ),
                        turnLifecycle = ConversationTurnLifecycle.Running,
                    ),
                )
            }
            "item/plan/delta", "item/reasoning/summaryTextDelta" -> {
                val threadId = event.params.firstString("threadId", "thread_id") ?: return
                if (threadId != _state.value.selectedThreadId) return
                val delta = event.params.string("delta").orEmpty()
                if (delta.isEmpty()) return
                val itemId = event.params.firstString("itemId", "item_id") ?: "${event.method}-${_state.value.activeTurnId.orEmpty()}"
                val turnId = event.params.firstString("turnId", "turn_id") ?: _state.value.activeTurnId
                appendStructuredActivityText(
                    itemId = itemId,
                    turnId = turnId,
                    category = if (event.method == "item/plan/delta") ConversationActivityCategory.Plan else ConversationActivityCategory.Thinking,
                    delta = delta,
                )
            }
            "item/mcpToolCall/progress" -> {
                val threadId = event.params.firstString("threadId", "thread_id") ?: return
                if (threadId != _state.value.selectedThreadId) return
                val message = event.params.firstString("message", "text") ?: return
                val itemId = event.params.firstString("itemId", "item_id") ?: "mcp-${_state.value.activeTurnId.orEmpty()}"
                val turnId = event.params.firstString("turnId", "turn_id") ?: _state.value.activeTurnId
                updateToolProgress(itemId, turnId, message)
            }
            "item/started" -> {
                val threadId = event.params.firstString("threadId", "thread_id") ?: return
                if (threadId != _state.value.selectedThreadId) return
                val item = event.params.objectAt("item") ?: return
                val turnId = event.params.firstString("turnId", "turn_id") ?: _state.value.activeTurnId
                if (item.string("type") == "agentMessage") {
                    item.string("id")?.let { itemId ->
                        if (item.string("phase") == "commentary") {
                            commentaryAgentItemIds += itemId
                        } else {
                            commentaryAgentItemIds -= itemId
                        }
                    }
                }
                updateThreadContext(
                    threadId,
                    SessionContextProjection.fromItem(threadId, turnId, item, "inProgress"),
                )
                AppServerProjection.conversationActivityMessage(
                    item = item,
                    turnId = turnId,
                    turnLifecycle = ConversationTurnLifecycle.Running,
                    statusOverride = "inProgress",
                    itemCompleted = false,
                )?.let(::upsertConversationMessage)
            }
            "item/agentMessage/delta" -> {
                val threadId = event.params.firstString("threadId", "thread_id") ?: return
                if (threadId != _state.value.selectedThreadId) return
                val delta = event.params.string("delta").orEmpty()
                if (delta.isEmpty()) return
                val itemId = event.params.firstString("itemId", "item_id")
                    ?: "assistant-${_state.value.activeTurnId ?: "stream"}"
                val turnId = event.params.firstString("turnId", "turn_id") ?: _state.value.activeTurnId
                val role = if (
                    event.params.firstString("phase") == "commentary" ||
                    itemId in commentaryAgentItemIds
                ) {
                    ConversationRole.Commentary
                } else {
                    ConversationRole.Assistant
                }
                _state.update { current ->
                    current.copy(
                        messages = ConversationTimelineStateReducer.appendAssistantText(
                            messages = current.messages,
                            itemId = itemId,
                            turnId = turnId,
                            delta = delta,
                            role = role,
                        ),
                    )
                }
            }
            "item/completed" -> {
                val threadId = event.params.firstString("threadId", "thread_id") ?: return
                if (threadId != _state.value.selectedThreadId) return
                val item = event.params.objectAt("item") ?: return
                val turnId = event.params.firstString("turnId", "turn_id") ?: _state.value.activeTurnId
                updateThreadContext(
                    threadId,
                    SessionContextProjection.fromItem(
                        threadId = threadId,
                        turnId = turnId,
                        item = item,
                        statusOverride = item.string("status") ?: "completed",
                    ),
                )
                if (item.string("type") == "agentMessage") {
                    val itemId = item.string("id") ?: return
                    val text = item.string("text").orEmpty()
                    val role = if (
                        item.string("phase") == "commentary" ||
                        itemId in commentaryAgentItemIds
                    ) {
                        ConversationRole.Commentary
                    } else {
                        ConversationRole.Assistant
                    }
                    commentaryAgentItemIds -= itemId
                    _state.update { current ->
                        current.copy(
                            messages = ConversationTimelineStateReducer.completeAssistantMessage(
                                messages = current.messages,
                                itemId = itemId,
                                turnId = turnId,
                                text = text,
                                role = role,
                            ),
                        )
                    }
                } else {
                    AppServerProjection.conversationActivityMessage(
                        item = item,
                        turnId = turnId,
                        turnLifecycle = ConversationTurnLifecycle.Running,
                        itemCompleted = true,
                    )?.let(::upsertConversationMessage)
                }
            }
            "item/commandExecution/outputDelta",
            "command/exec/outputDelta",
            "commandExecution/outputDelta",
            "command/execution/outputDelta",
            "process/outputDelta" -> {
                val threadId = event.params.firstString("threadId", "thread_id") ?: return
                if (threadId != _state.value.selectedThreadId) return
                val delta = event.params.firstString("delta", "data", "text", "chunk").orEmpty()
                if (delta.isEmpty()) return
                val itemId = event.params.firstString("itemId", "item_id") ?: return
                val turnId = event.params.firstString("turnId", "turn_id") ?: _state.value.activeTurnId
                appendCommandOutput(itemId, turnId, delta)
            }
            "turn/completed" -> {
                val completedThreadId = event.params.firstString("threadId", "thread_id") ?: _state.value.selectedThreadId
                val turn = event.params.objectAt("turn")
                val turnId = event.params.firstString("turnId", "turn_id")
                    ?: turn?.string("id")
                    ?: _state.value.activeTurnId
                val turnStatus = turn?.firstString("status", "state")
                    ?: turn?.objectAt("status")?.firstString("type", "status")
                    ?: event.params.firstString("status", "state")
                val lifecycle = turnLifecycle(turnStatus)
                completedThreadId?.let { threadId ->
                    updateThreadContext(
                        threadId,
                        SessionContextProjection.statusUpdate(
                            threadId,
                            turnStatus ?: if (lifecycle == ConversationTurnLifecycle.Failed) "failed" else "completed",
                        ),
                    )
                }
                if (completedThreadId != null && completedThreadId == _state.value.selectedThreadId) {
                    _state.update { current -> current.copy(
                        activeTurnId = null,
                        awaitingTurnIdentity = false,
                        guideActiveTurn = false,
                        messages = ConversationTimelineStateReducer.completeTurn(
                            messages = current.messages,
                            turnId = turnId,
                            lifecycle = lifecycle,
                        ),
                    ) }
                    reconcileCompletedTurnIfNeeded(completedThreadId, turnId)
                }
                val failed = lifecycle == ConversationTurnLifecycle.Failed
                postRuntimeNotification(
                    if (failed) RuntimeNotificationKind.Failure else RuntimeNotificationKind.Completion,
                    if (failed) container.string(R.string.notification_run_failed) else container.string(R.string.notification_run_finished),
                    _state.value.threads.firstOrNull { it.id == completedThreadId }?.preview ?: container.string(R.string.notification_tap_to_open),
                    completedThreadId,
                )
                if (completedThreadId == _state.value.selectedThreadId) flushNextQueuedTurn()
            }
            "thread/name/updated" -> {
                val threadId = event.params.firstString("threadId", "thread_id") ?: return
                val name = event.params.firstString("threadName", "thread_name", "name")?.trim().orEmpty()
                if (name.isEmpty()) return
                _state.update { current -> current.copy(
                    threads = current.threads.map { if (it.id == threadId) it.copy(preview = name) else it },
                    sessionSearchResults = current.sessionSearchResults.map { result ->
                        if (result.thread.id == threadId) result.copy(thread = result.thread.copy(preview = name)) else result
                    },
                ) }
                if (threadId == _state.value.selectedThreadId) {
                    upsertActivityMessage("thread-name-$threadId", container.string(R.string.session_renamed_activity, name))
                }
            }
            "thread/tokenUsage/updated" -> {
                val threadId = event.params.firstString("threadId", "thread_id") ?: return
                val summary = AppServerProjection.tokenUsageSummary(event.params) ?: return
                _state.update { it.copy(sessionTokenUsage = it.sessionTokenUsage + (threadId to summary)) }
            }
            "thread/status/changed" -> {
                val threadId = event.params.firstString("threadId", "thread_id") ?: return
                val status = event.params.objectAt("status")?.firstString("type", "status") ?: event.params.string("status")
                status?.let { updateThreadContext(threadId, SessionContextProjection.statusUpdate(threadId, it)) }
                if (threadId != _state.value.selectedThreadId) return
                if (status.equals("idle", true) || status.equals("closed", true) || status.equals("notLoaded", true)) {
                    _state.update { it.copy(activeTurnId = null, awaitingTurnIdentity = false, guideActiveTurn = false) }
                }
            }
            "thread/closed" -> {
                val threadId = event.params.firstString("threadId", "thread_id") ?: return
                if (threadId == _state.value.selectedThreadId) _state.update { it.copy(activeTurnId = null, awaitingTurnIdentity = false, guideActiveTurn = false) }
                _state.value.selectedProjectId?.let(::loadThreads)
            }
            "thread/compacted" -> {
                val threadId = event.params.firstString("threadId", "thread_id") ?: return
                if (threadId != _state.value.selectedThreadId) return
                viewModelScope.launch {
                    runCatching { requireNotNull(appServer).conversationPage(threadId) }
                        .onSuccess { page -> _state.update { current ->
                            if (current.selectedThreadId == threadId) {
                                current.copy(
                                    threads = mergeThreadContext(current.threads, threadId, page.context),
                                    messages = ConversationTimelineStateReducer.mergeSnapshot(
                                        current = current.messages,
                                        snapshot = page.messages,
                                    ),
                                    historyCursor = page.nextCursor,
                                )
                            } else {
                                current
                            }
                        } }
                }
            }
            "turn/diff/updated", "item/fileChange/patchUpdated", "fileChange/patchUpdated" -> {
                val threadId = event.params.firstString("threadId", "thread_id") ?: return
                if (threadId == _state.value.selectedThreadId) refreshGit()
            }
            "deprecationNotice" -> {
                val summary = event.params.firstString("summary", "message") ?: return
                val details = event.params.firstString("details", "detail")
                upsertActivityMessage("deprecation-${summary.hashCode()}", listOfNotNull(summary, details).joinToString("\n\n"))
            }
            "serverRequest/resolved" -> {
                val resolvedId = event.params.firstString("requestId", "request_id", "id", "approvalId", "itemId", "item_id")
                val threadId = event.params.firstString("threadId", "sessionId", "session_id")
                _state.update { current ->
                    current.copy(
                        pendingApprovals = current.pendingApprovals.filterValues { request ->
                            !resolvedRequestMatches(request.threadId, request.id, request.requestId, threadId, resolvedId)
                        },
                        pendingUserInputs = current.pendingUserInputs.filterValues { request ->
                            !resolvedRequestMatches(request.threadId, request.id, request.requestId, threadId, resolvedId)
                        },
                    )
                }
            }
        }
    }

    private fun updateThreadContext(threadId: String, update: SessionContextSnapshot?) {
        if (update == null) return
        _state.update { current ->
            current.copy(
                threads = mergeThreadContext(current.threads, threadId, update),
                sessionSearchResults = current.sessionSearchResults.map { result ->
                    if (result.thread.id == threadId) {
                        result.copy(
                            thread = result.thread.copy(
                                context = SessionContextStateReducer.merge(result.thread.context, update),
                            ),
                        )
                    } else {
                        result
                    }
                },
            )
        }
    }

    private fun mergeThreadContext(
        threads: List<AgentThread>,
        threadId: String,
        update: SessionContextSnapshot?,
    ): List<AgentThread> {
        if (update == null) return threads
        return threads.map { thread ->
            if (thread.id == threadId) {
                thread.copy(context = SessionContextStateReducer.merge(thread.context, update))
            } else {
                thread
            }
        }
    }

    private fun contextualizeThreads(
        incoming: List<AgentThread>,
        existing: List<AgentThread>,
    ): List<AgentThread> {
        val existingById = existing.associateBy(AgentThread::id)
        val merged = incoming.map { thread ->
            thread.copy(
                context = SessionContextStateReducer.merge(
                    existingById[thread.id]?.context,
                    thread.context,
                ),
            )
        }
        val subagentsByParent = buildMap<String, MutableList<com.gaixianggeng.mimi.core.model.SessionContextSubagent>> {
            merged.flatMap { it.context?.subagents.orEmpty() }.forEach { subagent ->
                val parent = subagent.parentThreadId?.takeIf(String::isNotBlank) ?: return@forEach
                val candidates = buildSet {
                    add(parent)
                    if (parent.startsWith("codex_")) add(parent.removePrefix("codex_"))
                    else add("codex_$parent")
                }
                candidates.forEach { candidate -> getOrPut(candidate) { mutableListOf() }.add(subagent) }
            }
        }
        return merged.map { thread ->
            val attached = subagentsByParent[thread.id].orEmpty()
            if (attached.isEmpty()) thread
            else thread.copy(
                context = SessionContextStateReducer.merge(
                    thread.context,
                    SessionContextSnapshot(threadId = thread.id, subagents = attached),
                ),
            )
        }
    }

    private fun upsertConversationMessage(incoming: ConversationMessage) {
        _state.update { current ->
            current.copy(
                messages = ConversationTimelineStateReducer.upsert(current.messages, incoming),
            )
        }
    }

    private fun reconcileCompletedTurnIfNeeded(threadId: String, turnId: String?) {
        if (!CompletionReconciliationPolicy.needsAuthoritativeSnapshot(_state.value.messages, turnId)) return
        viewModelScope.launch {
            for (retryDelay in listOf(350L, 1_000L, 2_500L)) {
                delay(retryDelay)
                val snapshot = _state.value
                if (snapshot.selectedThreadId != threadId) return@launch
                if (!CompletionReconciliationPolicy.needsAuthoritativeSnapshot(snapshot.messages, turnId)) return@launch
                runCatching { requireNotNull(appServer).conversationPage(threadId) }
                    .onSuccess { page ->
                        _state.update { current ->
                            if (current.selectedThreadId != threadId) {
                                current
                            } else {
                                current.copy(
                                    messages = ConversationTimelineStateReducer.mergeSnapshot(
                                        current = current.messages,
                                        snapshot = page.messages,
                                    ),
                                    historyCursor = current.historyCursor ?: page.nextCursor,
                                )
                            }
                        }
                    }
            }
        }
    }

    private fun appendStructuredActivityText(
        itemId: String,
        turnId: String?,
        category: ConversationActivityCategory,
        delta: String,
    ) {
        _state.update { current ->
            current.copy(
                messages = ConversationTimelineStateReducer.appendActivityText(
                    messages = current.messages,
                    itemId = itemId,
                    turnId = turnId,
                    category = category,
                    delta = delta,
                ),
            )
        }
    }

    private fun updateToolProgress(itemId: String, turnId: String?, progress: String) {
        _state.update { current ->
            current.copy(
                messages = ConversationTimelineStateReducer.updateToolProgress(
                    messages = current.messages,
                    itemId = itemId,
                    turnId = turnId,
                    progress = progress,
                ),
            )
        }
    }

    private fun appendCommandOutput(itemId: String, turnId: String?, delta: String) {
        _state.update { current ->
            current.copy(
                messages = ConversationTimelineStateReducer.appendCommandOutput(
                    messages = current.messages,
                    itemId = itemId,
                    turnId = turnId,
                    delta = delta,
                ),
            )
        }
    }

    private fun turnLifecycle(status: String?): ConversationTurnLifecycle {
        val normalized = status.orEmpty().lowercase().replace("_", "").replace("-", "").replace(" ", "")
        return when (normalized) {
            "completed", "complete", "succeeded", "success" -> ConversationTurnLifecycle.Completed
            "failed", "failure", "systemerror", "error" -> ConversationTurnLifecycle.Failed
            "interrupted", "cancelled", "canceled", "aborted" -> ConversationTurnLifecycle.Interrupted
            "active", "running", "inprogress" -> ConversationTurnLifecycle.Running
            else -> ConversationTurnLifecycle.Completed
        }
    }

    private fun upsertActivityMessage(id: String, text: String) {
        _state.update { current ->
            val message = ConversationMessage(id, ConversationRole.Activity, text)
            current.copy(
                messages = ConversationTimelineStateReducer.upsert(current.messages, message),
            )
        }
    }

    private fun appendDiagnosticLog(message: String) {
        _state.update { current ->
            current.copy(diagnosticLogs = DiagnosticLogPolicy.append(current.diagnosticLogs, message))
        }
    }

    override fun onCleared() {
        reconnectJob?.cancel()
        queuedDispatchJob?.cancel()
        appServerEventsJob?.cancel()
        appServerStatusJob?.cancel()
        appServer?.close()
        container.voiceRecorder.close()
    }

    private fun claimPairing(ticket: PairingLinkAssessment.SignedTicket) {
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            try {
                val response = container.apiClient.claimPairing(
                    ticket.endpoint,
                    PairingClaimRequest(ticket.endpoint, ticket.issuedAt, ticket.expiresAt, ticket.pairSignature),
                )
                _state.update { it.copy(endpoint = response.endpoint, token = response.token, loading = false) }
                connect()
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                _state.update { it.copy(loading = false, error = error.message ?: container.string(R.string.pairing_failed)) }
            }
        }
    }

    private fun showPairingLinkError(rejection: PairingLinkAssessment.Rejected) {
        val message = when (rejection.reason) {
            PairingLinkRejection.Unsupported -> container.string(R.string.unsupported_mimi_link)
            PairingLinkRejection.MissingEndpoint,
            PairingLinkRejection.IncompleteTicket -> container.string(R.string.pairing_link_incomplete)
            PairingLinkRejection.MissingToken -> container.string(R.string.legacy_link_incomplete)
            PairingLinkRejection.InvalidExpiry -> container.string(R.string.pairing_expiry_invalid)
            PairingLinkRejection.Expired -> container.string(R.string.pairing_link_expired)
            PairingLinkRejection.EndpointRejected -> localizedEndpointRejection(rejection.endpointReason.orEmpty())
        }
        showError(message)
    }
}

private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
private fun JsonObject.objectAt(key: String): JsonObject? = this[key] as? JsonObject
private fun JsonObject.firstString(vararg keys: String): String? = keys.firstNotNullOfOrNull(::string)
private fun resolvedRequestMatches(
    requestThreadId: String?,
    requestId: String,
    wireRequestId: kotlinx.serialization.json.JsonElement,
    resolvedThreadId: String?,
    resolvedId: String?,
): Boolean {
    if (resolvedThreadId == null && resolvedId == null) return false
    if (resolvedThreadId != null && requestThreadId != resolvedThreadId) return false
    if (resolvedId == null) return true
    val wireId = (wireRequestId as? JsonPrimitive)?.contentOrNull
    return requestId == resolvedId || wireId == resolvedId
}

class MainViewModelFactory(private val container: AppContainer) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T = MainViewModel(container) as T
}
