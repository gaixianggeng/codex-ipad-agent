package com.gaixianggeng.mimi.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

@Serializable
data class HealthResponse(
    val ok: Boolean,
    val version: String,
)

@Serializable
data class PairingClaimRequest(
    val endpoint: String,
    @SerialName("issued_at") val issuedAt: String,
    @SerialName("expires_at") val expiresAt: String,
    @SerialName("pair_sig") val pairSignature: String,
)

@Serializable
data class PairingClaimResponse(
    val endpoint: String,
    val token: String,
)

@Serializable
data class AgentProject(
    val id: String,
    val name: String,
    val path: String,
)

@Serializable
data class AgentProjectsResponse(
    val projects: List<AgentProject>,
)

@Serializable
data class ConnectionProfile(
    val id: String,
    val displayName: String,
    val endpoint: String,
    val createdAtEpochMillis: Long,
    val lastConnectedAtEpochMillis: Long? = null,
)

data class ConnectedAgent(
    val profile: ConnectionProfile,
    val version: String,
    val projects: List<AgentProject>,
)

data class ConnectionDiagnostic(
    val endpoint: String,
    val transport: String,
    val latencyMillis: Long,
    val agentVersion: String,
    val checkedAtEpochMillis: Long,
)

data class AgentThread(
    val id: String,
    val preview: String,
    val cwd: String,
    val createdAtEpochSeconds: Long? = null,
    val updatedAtEpochSeconds: Long? = null,
    val runtimeProvider: String = "codex",
    val context: SessionContextSnapshot? = null,
)

data class SessionContextSnapshot(
    val threadId: String,
    val status: SessionContextStatus? = null,
    val environment: SessionContextEnvironment? = null,
    val git: SessionContextGitInfo? = null,
    val tasks: List<SessionContextTask> = emptyList(),
    val sources: List<SessionContextSource> = emptyList(),
    val subagents: List<SessionContextSubagent> = emptyList(),
    val updatedAtEpochSeconds: Long? = null,
)

data class SessionContextStatus(
    val type: String,
    val activeFlags: List<String> = emptyList(),
    val rawType: String? = null,
)

data class SessionContextEnvironment(
    val id: String? = null,
    val kind: String? = null,
    val label: String? = null,
    val cwd: String? = null,
    val provider: String? = null,
    val runtimeProvider: String? = null,
)

data class SessionContextGitInfo(
    val sha: String? = null,
    val branch: String? = null,
    val originUrl: String? = null,
)

data class SessionContextTask(
    val id: String,
    val kind: String,
    val title: String,
    val subtitle: String? = null,
    val status: String? = null,
)

data class SessionContextSource(
    val id: String,
    val kind: String,
    val label: String,
    val subtitle: String? = null,
)

data class SessionContextSubagent(
    val id: String,
    val parentThreadId: String? = null,
    val nickname: String? = null,
    val role: String? = null,
    val status: String? = null,
) {
    val displayName: String get() = nickname?.takeIf(String::isNotBlank) ?: id.ifBlank { "Subagent" }
}

@Serializable
data class AppServerChannel(
    val id: String,
    @SerialName("runtime_id") val runtimeId: String? = null,
    val title: String,
    val provider: String,
    @SerialName("gateway_available") val gatewayAvailable: Boolean,
    val experimental: Boolean? = null,
)

@Serializable
data class AppServerConfig(val channels: List<AppServerChannel> = emptyList())

data class ThreadPage(
    val threads: List<AgentThread>,
    val nextCursor: String?,
)

data class ThreadSearchResult(
    val thread: AgentThread,
    val snippet: String,
)

data class ThreadSearchPage(
    val results: List<ThreadSearchResult>,
    val nextCursor: String?,
)

data class ModelOption(
    val id: String,
    val title: String,
    val provider: String? = null,
    val description: String? = null,
    val isDefault: Boolean = false,
    val supportedReasoningEfforts: List<String> = emptyList(),
    val defaultReasoningEffort: String? = null,
)

data class SkillCapability(
    val name: String,
    val description: String?,
    val scope: String,
    val path: String,
    val enabled: Boolean,
    val displayName: String? = null,
    val isManual: Boolean = false,
) {
    val presentationName: String get() = displayName?.takeIf(String::isNotBlank) ?: name
}

data class PluginCapability(
    val id: String,
    val name: String,
    val description: String? = null,
    val marketplace: String = "",
    val enabled: Boolean = true,
    val installed: Boolean = true,
)

enum class ConversationRole { User, Assistant, Commentary, Activity }

enum class ConversationActivityCategory {
    Thinking,
    Plan,
    RunCommand,
    EditFile,
    ToolCall,
    Error,
}

enum class ConversationCommandPresentationKind {
    Exploration,
    Execution,
}

enum class ConversationTurnLifecycle {
    Unknown,
    Running,
    Completed,
    Interrupted,
    Failed,
}

data class ConversationActivity(
    val category: ConversationActivityCategory,
    val title: String,
    val subtitle: String? = null,
    val status: String? = null,
    val command: String? = null,
    val cwd: String? = null,
    val toolName: String? = null,
    val filePaths: List<String> = emptyList(),
    val exitCode: Int? = null,
    val outputPreview: String? = null,
    val outputTruncated: Boolean = false,
    val commandPresentationKind: ConversationCommandPresentationKind? = null,
) {
    val normalizedStatus: String
        get() = status.orEmpty()
            .trim()
            .lowercase()
            .replace("_", "")
            .replace("-", "")
            .replace(" ", "")

    val isRunning: Boolean
        get() = normalizedStatus in setOf("inprogress", "running", "started")

    val isPending: Boolean
        get() = normalizedStatus in setOf("pending", "queued")

    val isFailure: Boolean
        get() = exitCode?.let { it != 0 } == true ||
            normalizedStatus in setOf("failed", "failure", "error")

    val isCancelled: Boolean
        get() = normalizedStatus in setOf("cancelled", "canceled", "interrupted", "aborted")

    val isComplete: Boolean
        get() = !isRunning && !isPending && !isFailure && !isCancelled &&
            normalizedStatus in setOf(
                "completed",
                "complete",
                "success",
                "succeeded",
                "modified",
                "added",
                "created",
                "deleted",
                "removed",
            )
}

enum class ConversationAttachmentKind { Image, LocalImage, Mention, Skill }

data class ConversationAttachment(
    val kind: ConversationAttachmentKind,
    val name: String? = null,
    val path: String? = null,
    val url: String? = null,
    val detail: String? = null,
)

enum class PermissionMode(val wireName: String) {
    RequestApproval("requestApproval"),
    ReadOnly("readOnly"),
    AutoApprove("autoApprove"),
    FullAccess("fullAccess");

    val approvalPolicy: String get() = if (this == AutoApprove) "on-failure" else "on-request"
    val approvalsReviewer: String get() = if (this == AutoApprove) "auto_review" else "user"
    val threadSandbox: String get() = when (this) {
        ReadOnly -> "read-only"
        RequestApproval, AutoApprove -> "workspace-write"
        FullAccess -> "danger-full-access"
    }
    val turnSandboxType: String get() = when (this) {
        ReadOnly -> "readOnly"
        RequestApproval, AutoApprove -> "workspaceWrite"
        FullAccess -> "dangerFullAccess"
    }

    companion object {
        fun fromWire(value: String?): PermissionMode = entries.firstOrNull { it.wireName == value } ?: FullAccess
    }
}

data class ConversationMessage(
    val id: String,
    val role: ConversationRole,
    val text: String,
    val streaming: Boolean = false,
    val attachments: List<ConversationAttachment> = emptyList(),
    val turnId: String? = null,
    val itemId: String? = null,
    val activity: ConversationActivity? = null,
    val turnLifecycle: ConversationTurnLifecycle = ConversationTurnLifecycle.Unknown,
    val itemCompleted: Boolean = false,
)

data class ConversationPage(
    val messages: List<ConversationMessage>,
    val nextCursor: String?,
    val context: SessionContextSnapshot? = null,
)

enum class ThreadGoalStatus(val wireName: String) {
    Active("active"),
    Paused("paused"),
    Blocked("blocked"),
    UsageLimited("usageLimited"),
    BudgetLimited("budgetLimited"),
    Complete("complete");

    companion object {
        fun fromWire(value: String?): ThreadGoalStatus? = entries.firstOrNull { it.wireName == value }
    }
}

data class ThreadGoal(
    val threadId: String,
    val objective: String,
    val status: ThreadGoalStatus,
    val tokenBudget: Long? = null,
    val tokensUsed: Long = 0,
    val timeUsedSeconds: Long = 0,
    val createdAtEpochSeconds: Long? = null,
    val updatedAtEpochSeconds: Long? = null,
)

data class RateLimitSummary(
    val planType: String? = null,
    val reachedType: String? = null,
    val primaryUsedPercent: Double? = null,
    val secondaryUsedPercent: Double? = null,
    val primaryResetsAt: Long? = null,
    val secondaryResetsAt: Long? = null,
    val primaryWindowDurationMinutes: Int? = null,
    val secondaryWindowDurationMinutes: Int? = null,
    val availability: String? = null,
    val unavailableReason: String? = null,
)

enum class ReviewTargetKind { UncommittedChanges, BaseBranch, Commit }

data class ReviewStartResult(val reviewThreadId: String, val turnId: String? = null)

data class ApprovalRequest(
    val requestId: JsonElement,
    val method: String,
    val params: JsonObject,
    val id: String,
    val threadId: String?,
    val title: String,
    val body: String?,
    val kind: String,
    val risk: String?,
    val availableDecisions: List<String> = emptyList(),
    val persistentPermissionRules: List<String> = emptyList(),
    val count: Int? = null,
)

data class UserInputOption(val label: String, val description: String?)

data class UserInputQuestion(
    val id: String,
    val header: String,
    val question: String,
    val isOther: Boolean,
    val isSecret: Boolean,
    val options: List<UserInputOption>,
    val multiSelect: Boolean,
)

data class UserInputRequest(
    val requestId: JsonElement,
    val method: String,
    val params: JsonObject,
    val id: String,
    val threadId: String,
    val turnId: String?,
    val questions: List<UserInputQuestion>,
)

@Serializable
enum class GitActionKind {
    @SerialName("stage") Stage,
    @SerialName("unstage") Unstage,
    @SerialName("revert") Revert,
    @SerialName("stage_patch") StagePatch,
    @SerialName("unstage_patch") UnstagePatch,
    @SerialName("revert_patch") RevertPatch,
}

@Serializable
data class GitFileStatus(
    val path: String,
    val code: String,
    val staged: Boolean = false,
    val unstaged: Boolean = false,
    val untracked: Boolean = false,
)

@Serializable
data class GitStatusResponse(
    val path: String,
    @SerialName("is_repository") val isRepository: Boolean,
    val branch: String? = null,
    val head: String? = null,
    @SerialName("status_text") val statusText: String? = null,
    @SerialName("diff_stat") val diffStat: String? = null,
    @SerialName("unstaged_diff") val unstagedDiff: String? = null,
    @SerialName("staged_diff") val stagedDiff: String? = null,
    val files: List<GitFileStatus> = emptyList(),
    val truncated: Boolean? = null,
    @SerialName("truncated_note") val truncatedNote: String? = null,
)

@Serializable
data class GitStatusRequest(val path: String)

@Serializable
data class GitActionRequest(
    val path: String,
    val action: GitActionKind,
    val files: List<String> = emptyList(),
    val patch: String? = null,
)

@Serializable
data class GitCommitRequest(val path: String, val message: String)

@Serializable
data class GitPushRequest(val path: String, val remote: String? = null)

@Serializable
data class GitPushResponse(
    val path: String,
    val remote: String,
    val branch: String,
    val output: String? = null,
    val status: GitStatusResponse,
)

@Serializable
data class GitQuickPublishRequest(val path: String, val message: String, val remote: String? = null, val confirmed: Boolean)

@Serializable
data class GitQuickPublishResponse(
    val path: String,
    val remote: String,
    val branch: String,
    val message: String,
    val committed: Boolean,
    val output: String? = null,
    val status: GitStatusResponse,
)

@Serializable
data class GitPullRequestRequest(val path: String, val title: String, val body: String, val draft: Boolean)

@Serializable
data class GitPullRequestStatusRequest(val path: String)

@Serializable
data class GitPullRequestResponse(val path: String, val branch: String, val url: String? = null, val output: String? = null)

@Serializable
data class GitPullRequestStatusResponse(
    val path: String,
    val branch: String,
    val exists: Boolean,
    val number: Int? = null,
    val title: String? = null,
    val state: String? = null,
    val url: String? = null,
    @SerialName("is_draft") val isDraft: Boolean = false,
    @SerialName("review_decision") val reviewDecision: String? = null,
    @SerialName("merge_state_status") val mergeStateStatus: String? = null,
    @SerialName("head_ref_name") val headRefName: String? = null,
    @SerialName("base_ref_name") val baseRefName: String? = null,
)

@Serializable
data class GitTestFlightStatusRequest(val path: String)

@Serializable
data class GitTestFlightRunRequest(
    val path: String,
    @SerialName("what_to_test") val whatToTest: String,
    val confirmed: Boolean,
)

@Serializable
data class GitTestFlightCapability(
    @SerialName("is_ios_project") val isIosProject: Boolean,
    val available: Boolean,
    val reason: String,
    @SerialName("project_id") val projectId: String? = null,
    val command: String? = null,
)

@Serializable
data class GitTestFlightJob(
    val id: String,
    val state: String,
    val output: String? = null,
    val truncated: Boolean? = null,
    @SerialName("exit_code") val exitCode: Int? = null,
    @SerialName("started_at") val startedAt: String,
    @SerialName("finished_at") val finishedAt: String? = null,
)

@Serializable
data class GitTestFlightStatusResponse(
    val path: String,
    val capability: GitTestFlightCapability,
    val job: GitTestFlightJob? = null,
)

@Serializable
data class VoiceTranscriptionRequest(
    val filename: String,
    @SerialName("content_type") val contentType: String,
    @SerialName("audio_base64") val audioBase64: String,
    val language: String? = null,
)

@Serializable
data class VoiceTranscriptionResponse(
    val text: String,
    val model: String,
)

@Serializable
data class FileReadRequest(val path: String)

@Serializable
data class FileReadResponse(
    val path: String,
    val name: String,
    @SerialName("content_type") val contentType: String,
    val size: Long,
    @SerialName("content_base64") val contentBase64: String,
)

@Serializable
data class WorkspaceResolveRequest(val path: String)

@Serializable
data class WorkspaceResolveResponse(val workspace: AgentWorkspace)

@Serializable
data class DirectoryListRequest(val path: String)

@Serializable
data class DirectoryEntry(
    val name: String,
    val path: String,
    @SerialName("is_dir") val isDir: Boolean,
    @SerialName("can_open") val canOpen: Boolean,
    @SerialName("can_browse") val canBrowse: Boolean,
    @SerialName("can_preview") val canPreview: Boolean = false,
)

@Serializable
data class DirectoryListResponse(
    val path: String,
    @SerialName("parent_path") val parentPath: String? = null,
    val entries: List<DirectoryEntry> = emptyList(),
    val truncated: Boolean? = null,
)

@Serializable
data class CommandActionListRequest(val path: String)

@Serializable
data class CommandActionRunRequest(val path: String, val id: String, val confirmed: Boolean)

@Serializable
data class AgentCommandAction(
    val id: String,
    val name: String,
    val command: String,
    val args: List<String> = emptyList(),
    @SerialName("working_dir") val workingDir: String,
    @SerialName("timeout_seconds") val timeoutSeconds: Int,
    @SerialName("requires_confirmation") val requiresConfirmation: Boolean = false,
) {
    val displayCommand: String get() = (listOf(command) + args).joinToString(" ")
}

@Serializable
data class CommandActionListResponse(val path: String, val actions: List<AgentCommandAction> = emptyList())

@Serializable
data class CommandActionRunResponse(
    val id: String,
    val name: String,
    val path: String,
    @SerialName("working_dir") val workingDir: String,
    val command: String,
    val args: List<String> = emptyList(),
    val success: Boolean,
    @SerialName("exit_code") val exitCode: Int,
    val output: String? = null,
    val truncated: Boolean? = null,
    @SerialName("timed_out") val timedOut: Boolean? = null,
    @SerialName("duration_ms") val durationMs: Long,
)

@Serializable
data class AgentWorkspace(
    val id: String,
    val name: String,
    val path: String,
    @SerialName("root_project_id") val rootProjectId: String? = null,
    @SerialName("root_project_name") val rootProjectName: String? = null,
    @SerialName("root_project_path") val rootProjectPath: String? = null,
)

@Serializable
data class WorktreeDescriptor(
    val path: String,
    @SerialName("repository_path") val repositoryPath: String,
    val base: String,
    val branch: String? = null,
    @SerialName("git_state") val gitState: String = "unknown",
    val dirty: Boolean = false,
    val ahead: Int = 0,
    val behind: Int = 0,
    val upstream: String? = null,
    @SerialName("root_project_id") val rootProjectId: String,
    @SerialName("root_project_name") val rootProjectName: String,
    @SerialName("root_project_path") val rootProjectPath: String,
)

@Serializable
data class WorktreeListItem(val workspace: AgentWorkspace, val worktree: WorktreeDescriptor)

@Serializable
data class WorktreeListResponse(val worktrees: List<WorktreeListItem> = emptyList())

@Serializable
data class WorktreeBranchListRequest(val path: String)

@Serializable
data class WorktreeBranchItem(
    val name: String,
    val kind: String,
    @SerialName("is_current") val isCurrent: Boolean = false,
    @SerialName("is_default") val isDefault: Boolean = false,
)

@Serializable
data class WorktreeBranchListResponse(
    val path: String,
    @SerialName("default_base") val defaultBase: String? = null,
    @SerialName("current_branch") val currentBranch: String? = null,
    val branches: List<WorktreeBranchItem> = emptyList(),
)

@Serializable
data class RelayGatewaySummary(
    @SerialName("total_connections") val totalConnections: Long = 0,
    @SerialName("active_connections") val activeConnections: Long = 0,
    @SerialName("failed_upstream_dials") val failedUpstreamDials: Long = 0,
    @SerialName("upstream_dial_ms_max") val upstreamDialMillisMax: Long = 0,
    @SerialName("policy_errors") val policyErrors: Long = 0,
)

@Serializable
data class RelayDiagnosticsResponse(
    @SerialName("generated_at") val generatedAt: String,
    @SerialName("app_server_gateway") val appServerGateway: RelayGatewaySummary,
    val hints: List<String>? = emptyList(),
)

@Serializable
data class TailscaleNetworkPathResponse(
    val kind: String,
    @SerialName("observed_at") val observedAt: String,
    @SerialName("relay_region") val relayRegion: String? = null,
)

@Serializable
data class WorktreeCreateRequest(val path: String, val name: String? = null, val base: String? = null, val branch: String? = null)

@Serializable
data class WorktreeCreateResponse(val workspace: AgentWorkspace, val worktree: WorktreeDescriptor)

@Serializable
data class WorktreeDeleteRequest(val path: String, val force: Boolean)

@Serializable
data class WorktreeDeleteResponse(
    @SerialName("deleted_path") val deletedPath: String,
    val worktrees: List<WorktreeListItem> = emptyList(),
    @SerialName("registry_cleanup_error") val registryCleanupError: String? = null,
)

@Serializable
data class WorktreePruneResponse(
    @SerialName("pruned_paths") val prunedPaths: List<String> = emptyList(),
    @SerialName("failed_paths") val failedPaths: Map<String, String> = emptyMap(),
    val worktrees: List<WorktreeListItem> = emptyList(),
)

@Serializable
data class WorktreeCleanupRequest(
    @SerialName("dry_run") val dryRun: Boolean? = null,
    val confirm: Boolean? = null,
    val paths: List<String>? = null,
    @SerialName("plan_id") val planId: String? = null,
)

@Serializable
data class WorktreeCleanupPolicy(
    @SerialName("auto_delete") val autoDelete: Boolean,
    @SerialName("candidate_after_days") val candidateAfterDays: Int,
    @SerialName("keep_latest_per_project") val keepLatestPerProject: Int,
)

@Serializable
data class WorktreeCleanupItem(
    val workspace: AgentWorkspace,
    val worktree: WorktreeDescriptor,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("last_used_at") val lastUsedAt: String? = null,
    val eligible: Boolean,
    val blockers: List<String> = emptyList(),
)

@Serializable
data class WorktreeCleanupResponse(
    @SerialName("dry_run") val dryRun: Boolean,
    @SerialName("plan_id") val planId: String? = null,
    val policy: WorktreeCleanupPolicy,
    @SerialName("generated_at") val generatedAt: String,
    val worktrees: List<WorktreeCleanupItem> = emptyList(),
    @SerialName("candidate_paths") val candidatePaths: List<String> = emptyList(),
    @SerialName("deleted_paths") val deletedPaths: List<String> = emptyList(),
    @SerialName("failed_path") val failedPath: String? = null,
    val error: String? = null,
)

@Serializable
data class DoctorCheck(
    val name: String,
    val ok: Boolean,
    val level: String = "",
    val message: String,
    val fix: String? = null,
)

@Serializable
data class DoctorResults(
    val ok: Boolean,
    val version: String,
    val listen: String = "",
    val checks: List<DoctorCheck> = emptyList(),
)

@Serializable
data class CapabilityListRequest(val path: String? = null)

@Serializable
data class McpServerCapability(
    val name: String,
    val scope: String,
    @SerialName("config_path") val configPath: String,
    val transport: String? = null,
    val command: String? = null,
    val url: String? = null,
    val enabled: Boolean,
    val plugin: String? = null,
    val status: String? = null,
    @SerialName("status_note") val statusNote: String? = null,
)

@Serializable
data class LegacyCapabilityListResponse(
    val path: String? = null,
    val skills: List<SkillCapabilityWire> = emptyList(),
    @SerialName("mcp_servers") val mcpServers: List<McpServerCapability> = emptyList(),
)

@Serializable
data class SkillCapabilityWire(
    val name: String,
    val description: String? = null,
    val scope: String,
    val path: String,
    val enabled: Boolean,
)
