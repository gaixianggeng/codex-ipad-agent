package com.gaixianggeng.mimi.core.network

import com.gaixianggeng.mimi.core.model.AgentProject
import com.gaixianggeng.mimi.core.model.AgentProjectsResponse
import com.gaixianggeng.mimi.core.model.HealthResponse
import com.gaixianggeng.mimi.core.model.GitActionKind
import com.gaixianggeng.mimi.core.model.GitActionRequest
import com.gaixianggeng.mimi.core.model.GitMutationPolicy
import com.gaixianggeng.mimi.core.model.GitPublishPolicy
import com.gaixianggeng.mimi.core.model.GitStatusPolicy
import com.gaixianggeng.mimi.core.model.GitCommitRequest
import com.gaixianggeng.mimi.core.model.GitPushRequest
import com.gaixianggeng.mimi.core.model.GitPushResponse
import com.gaixianggeng.mimi.core.model.GitStatusRequest
import com.gaixianggeng.mimi.core.model.GitStatusResponse
import com.gaixianggeng.mimi.core.model.PairingClaimRequest
import com.gaixianggeng.mimi.core.model.PairingClaimResponse
import com.gaixianggeng.mimi.core.model.VoiceTranscriptionRequest
import com.gaixianggeng.mimi.core.model.VoiceTranscriptionResponse
import com.gaixianggeng.mimi.core.model.FileReadRequest
import com.gaixianggeng.mimi.core.model.FileReadResponse
import com.gaixianggeng.mimi.core.model.WorktreeListResponse
import com.gaixianggeng.mimi.core.model.WorktreeBranchListRequest
import com.gaixianggeng.mimi.core.model.WorktreeBranchListResponse
import com.gaixianggeng.mimi.core.model.RelayDiagnosticsResponse
import com.gaixianggeng.mimi.core.model.TailscaleNetworkPathResponse
import com.gaixianggeng.mimi.core.model.WorktreeCreateRequest
import com.gaixianggeng.mimi.core.model.WorktreeCreateResponse
import com.gaixianggeng.mimi.core.model.WorktreeDeleteRequest
import com.gaixianggeng.mimi.core.model.WorktreeDeleteResponse
import com.gaixianggeng.mimi.core.model.WorktreePruneResponse
import com.gaixianggeng.mimi.core.model.WorktreeCleanupRequest
import com.gaixianggeng.mimi.core.model.WorktreeCleanupResponse
import com.gaixianggeng.mimi.core.model.DoctorResults
import com.gaixianggeng.mimi.core.model.CapabilityListRequest
import com.gaixianggeng.mimi.core.model.LegacyCapabilityListResponse
import com.gaixianggeng.mimi.core.model.WorkspaceResolveRequest
import com.gaixianggeng.mimi.core.model.WorkspaceResolveResponse
import com.gaixianggeng.mimi.core.model.AgentWorkspace
import com.gaixianggeng.mimi.core.model.DirectoryListRequest
import com.gaixianggeng.mimi.core.model.DirectoryListResponse
import com.gaixianggeng.mimi.core.model.CommandActionListRequest
import com.gaixianggeng.mimi.core.model.CommandActionListResponse
import com.gaixianggeng.mimi.core.model.CommandActionRunRequest
import com.gaixianggeng.mimi.core.model.CommandActionRunResponse
import com.gaixianggeng.mimi.core.model.GitQuickPublishRequest
import com.gaixianggeng.mimi.core.model.GitQuickPublishResponse
import com.gaixianggeng.mimi.core.model.GitPullRequestRequest
import com.gaixianggeng.mimi.core.model.GitPullRequestResponse
import com.gaixianggeng.mimi.core.model.GitPullRequestStatusRequest
import com.gaixianggeng.mimi.core.model.GitPullRequestStatusResponse
import com.gaixianggeng.mimi.core.model.GitTestFlightStatusRequest
import com.gaixianggeng.mimi.core.model.GitTestFlightRunRequest
import com.gaixianggeng.mimi.core.model.GitTestFlightStatusResponse
import com.gaixianggeng.mimi.core.model.AppServerConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class AgentApiException(message: String, val statusCode: Int? = null) : IOException(message)

class AgentApiClient(
    private val client: OkHttpClient,
    private val json: Json,
) {
    suspend fun ready(endpoint: String, token: String): HealthResponse =
        get(endpoint, "/api/readyz", token)

    suspend fun doctor(endpoint: String, token: String): DoctorResults =
        get(endpoint, "/api/doctor", token)

    suspend fun capabilities(endpoint: String, token: String, path: String?): LegacyCapabilityListResponse =
        post(endpoint, "/api/capabilities/list", token, CapabilityListRequest(path))

    suspend fun projects(endpoint: String, token: String): List<AgentProject> =
        get<AgentProjectsResponse>(endpoint, "/api/projects", token).projects

    suspend fun appServerConfig(endpoint: String, token: String): AppServerConfig =
        get(endpoint, "/api/app-server/config", token)

    suspend fun relayDiagnostics(endpoint: String, token: String): RelayDiagnosticsResponse =
        get(endpoint, "/api/diagnostics/relay", token)

    suspend fun tailscaleNetworkPath(endpoint: String, token: String): TailscaleNetworkPathResponse =
        get(endpoint, "/api/diagnostics/tailscale-path", token)

    suspend fun codexHistoryDiagnostics(endpoint: String, token: String, projectId: String, limit: Int = 120): JsonObject {
        val normalizedLimit = limit.coerceIn(1, 200)
        val normalizedProject = projectId.trim()
        require(normalizedProject.length in 1..512) { "A bounded project scope is required" }
        val encodedProject = java.net.URLEncoder.encode(normalizedProject, Charsets.UTF_8.name()).replace("+", "%20")
        val query = buildString {
            append("?limit=").append(normalizedLimit)
            append("&project_id=").append(encodedProject)
        }
        return get(endpoint, "/api/debug/codex-history$query", token)
    }

    suspend fun resolveWorkspace(endpoint: String, token: String, path: String): AgentWorkspace =
        post<WorkspaceResolveRequest, WorkspaceResolveResponse>(endpoint, "/api/workspaces/resolve", token, WorkspaceResolveRequest(path)).workspace

    suspend fun listDirectories(endpoint: String, token: String, path: String): DirectoryListResponse =
        post(endpoint, "/api/directories/list", token, DirectoryListRequest(path))

    suspend fun commandActions(endpoint: String, token: String, path: String): CommandActionListResponse {
        val normalizedPath = boundedActionField(path, 4096, "Action path")
        return post(endpoint, "/api/actions/list", token, CommandActionListRequest(normalizedPath))
    }

    suspend fun runCommandAction(endpoint: String, token: String, path: String, id: String, confirmed: Boolean): CommandActionRunResponse {
        val normalizedPath = boundedActionField(path, 4096, "Action path")
        val normalizedId = boundedActionField(id, 256, "Action id")
        return post(endpoint, "/api/actions/run", token, CommandActionRunRequest(normalizedPath, normalizedId, confirmed))
    }

    private fun boundedActionField(value: String, maxLength: Int, label: String): String {
        val normalized = value.trim()
        require(value == normalized && value.length in 1..maxLength) { "$label is invalid" }
        return value
    }

    suspend fun gitStatus(endpoint: String, token: String, path: String): GitStatusResponse =
        post<GitStatusRequest, GitStatusResponse>(
            endpoint,
            "/api/git/status",
            token,
            GitPublishPolicy.statusRequest(path),
        ).let { GitStatusPolicy.sanitize(it, path) }

    suspend fun gitAction(endpoint: String, token: String, path: String, action: GitActionKind, files: List<String>): GitStatusResponse =
        post<GitActionRequest, GitStatusResponse>(
            endpoint,
            "/api/git/action",
            token,
            GitMutationPolicy.fileRequest(path, action, files),
        ).let { GitStatusPolicy.sanitize(it, path) }

    suspend fun gitPatchAction(endpoint: String, token: String, path: String, action: GitActionKind, patch: String): GitStatusResponse =
        post<GitActionRequest, GitStatusResponse>(
            endpoint,
            "/api/git/action",
            token,
            GitMutationPolicy.patchRequest(path, action, patch),
        ).let { GitStatusPolicy.sanitize(it, path) }

    suspend fun gitCommit(endpoint: String, token: String, path: String, message: String): GitStatusResponse =
        post<GitCommitRequest, GitStatusResponse>(
            endpoint,
            "/api/git/commit",
            token,
            GitPublishPolicy.commitRequest(path, message),
        ).let { GitStatusPolicy.sanitize(it, path) }

    suspend fun gitPush(endpoint: String, token: String, path: String, remote: String? = null): GitPushResponse =
        post<GitPushRequest, GitPushResponse>(endpoint, "/api/git/push", token, GitPublishPolicy.pushRequest(path, remote))
            .let(GitPublishPolicy::bound)
            .let { it.copy(status = GitStatusPolicy.sanitize(it.status, path)) }

    suspend fun gitQuickPublish(endpoint: String, token: String, path: String, message: String, confirmed: Boolean): GitQuickPublishResponse =
        post<GitQuickPublishRequest, GitQuickPublishResponse>(
            endpoint,
            "/api/git/quick-publish",
            token,
            GitPublishPolicy.quickPublishRequest(path, message, confirmed),
        ).let(GitPublishPolicy::bound)
            .let { it.copy(status = GitStatusPolicy.sanitize(it.status, path)) }

    suspend fun gitCreatePullRequest(endpoint: String, token: String, path: String, title: String, body: String, draft: Boolean): GitPullRequestResponse =
        post<GitPullRequestRequest, GitPullRequestResponse>(
            endpoint,
            "/api/git/pull-request",
            token,
            GitPublishPolicy.pullRequest(path, title, body, draft),
        ).let(GitPublishPolicy::bound)

    suspend fun gitPullRequestStatus(endpoint: String, token: String, path: String): GitPullRequestStatusResponse =
        post(endpoint, "/api/git/pull-request/status", token, GitPublishPolicy.pullRequestStatus(path))

    suspend fun gitTestFlightStatus(endpoint: String, token: String, path: String): GitTestFlightStatusResponse =
        post<GitTestFlightStatusRequest, GitTestFlightStatusResponse>(
            endpoint,
            "/api/git/testflight/status",
            token,
            GitPublishPolicy.testFlightStatus(path),
        ).let(GitPublishPolicy::bound)

    suspend fun gitTestFlightRun(endpoint: String, token: String, path: String, whatToTest: String, confirmed: Boolean): GitTestFlightStatusResponse =
        post<GitTestFlightRunRequest, GitTestFlightStatusResponse>(
            endpoint,
            "/api/git/testflight/run",
            token,
            GitPublishPolicy.testFlightRun(path, whatToTest, confirmed),
        ).let(GitPublishPolicy::bound)

    suspend fun transcribeVoice(
        endpoint: String,
        token: String,
        filename: String,
        contentType: String,
        audioBase64: String,
        language: String? = null,
    ): VoiceTranscriptionResponse = post(
        endpoint,
        "/api/voice/transcribe",
        token,
        VoiceTranscriptionRequest(filename, contentType, audioBase64, language),
    )

    suspend fun readFile(endpoint: String, token: String, path: String): FileReadResponse =
        post(endpoint, "/api/files/read", token, FileReadRequest(path))

    suspend fun readHistoryMedia(endpoint: String, token: String, id: String): FileReadResponse {
        val normalized = id.trim()
        require(normalized.isNotEmpty() && normalized.length <= 256) { "History media id is invalid" }
        val encoded = java.net.URLEncoder.encode(normalized, Charsets.UTF_8.name()).replace("+", "%20")
        return get(endpoint, "/api/app-server/history-media/$encoded", token)
    }

    suspend fun listWorktrees(endpoint: String, token: String): WorktreeListResponse =
        get(endpoint, "/api/worktrees/list", token)

    suspend fun listWorktreeBranches(endpoint: String, token: String, path: String): WorktreeBranchListResponse {
        val normalizedPath = boundedWorktreePath(path)
        return post(endpoint, "/api/worktrees/branches", token, WorktreeBranchListRequest(normalizedPath))
    }

    suspend fun createWorktree(endpoint: String, token: String, path: String, name: String?, base: String?): WorktreeCreateResponse {
        val normalizedPath = boundedWorktreePath(path)
        val normalizedName = name?.trim()?.takeIf(String::isNotEmpty)
        val normalizedBase = base?.trim()?.takeIf(String::isNotEmpty)
        require(normalizedName == null || normalizedName.length <= 256) { "Worktree name is too long" }
        require(normalizedBase == null || normalizedBase.length <= 512) { "Worktree base is too long" }
        return post(
            endpoint,
            "/api/worktrees/create",
            token,
            WorktreeCreateRequest(normalizedPath, normalizedName, normalizedBase),
        )
    }

    suspend fun deleteWorktree(endpoint: String, token: String, path: String): WorktreeDeleteResponse =
        post(endpoint, "/api/worktrees/delete", token, WorktreeDeleteRequest(boundedWorktreePath(path), force = false))

    suspend fun pruneWorktrees(endpoint: String, token: String): WorktreePruneResponse =
        post(endpoint, "/api/worktrees/prune", token, buildJsonObject { })

    private fun boundedWorktreePath(path: String): String {
        val normalized = path.trim()
        require(normalized.length in 1..4096) { "Worktree path is invalid" }
        return normalized
    }

    suspend fun previewWorktreeCleanup(endpoint: String, token: String): WorktreeCleanupResponse =
        post(endpoint, "/api/worktrees/cleanup", token, WorktreeCleanupRequest())

    suspend fun executeWorktreeCleanup(endpoint: String, token: String, paths: List<String>, planId: String): WorktreeCleanupResponse {
        require(paths.size in 1..500) { "Cleanup candidates are invalid" }
        require(paths.distinct().size == paths.size) { "Cleanup candidates must be unique" }
        require(paths.all { it == it.trim() && it.length in 1..4096 }) { "Cleanup candidate path is invalid" }
        require(planId == planId.trim() && planId.length in 1..512) { "Cleanup plan id is invalid" }
        return post(endpoint, "/api/worktrees/cleanup", token, WorktreeCleanupRequest(false, true, paths, planId))
    }

    suspend fun claimPairing(endpoint: String, claim: PairingClaimRequest): PairingClaimResponse {
        val normalized = normalizedEndpoint(endpoint)
        val body = json.encodeToString(claim).toRequestBody(JSON_MEDIA_TYPE)
        val request = Request.Builder()
            .url("$normalized/api/pair/claim")
            .post(body)
            .build()
        return executeAndDecode(request)
    }

    private suspend inline fun <reified T> get(endpoint: String, path: String, token: String): T {
        val request = Request.Builder()
            .url("${normalizedEndpoint(endpoint)}$path")
            .header("Authorization", "Bearer $token")
            .get()
            .build()
        return executeAndDecode(request)
    }

    private suspend inline fun <reified RequestType, reified ResponseType> post(
        endpoint: String,
        path: String,
        token: String,
        bodyValue: RequestType,
    ): ResponseType {
        val body = json.encodeToString(bodyValue).toRequestBody(JSON_MEDIA_TYPE)
        val request = Request.Builder()
            .url("${normalizedEndpoint(endpoint)}$path")
            .header("Authorization", "Bearer $token")
            .post(body)
            .build()
        return executeAndDecode(request)
    }

    private fun normalizedEndpoint(raw: String): String = when (val assessment = EndpointPolicy.assess(raw)) {
        is EndpointAssessment.Allowed -> assessment.normalizedEndpoint
        is EndpointAssessment.Rejected -> throw AgentApiException(assessment.reason)
    }

    private suspend inline fun <reified T> executeAndDecode(request: Request): T {
        val response = client.newCall(request).await()
        return withContext(Dispatchers.IO) {
            response.use {
                val body = it.body.string()
                if (!it.isSuccessful) {
                    val safeMessage = when (it.code) {
                        401 -> "Authentication failed"
                        403 -> "Request was forbidden"
                        else -> "Server returned HTTP ${it.code}"
                    }
                    throw AgentApiException(safeMessage, it.code)
                }
                try {
                    json.decodeFromString(body)
                } catch (error: kotlinx.serialization.SerializationException) {
                    throw AgentApiException(
                        "Could not decode ${request.url.encodedPath} response: " +
                            (error.message ?: error::class.simpleName.orEmpty()),
                    )
                }
            }
        }
    }

    private suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { cancel() }
        enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (continuation.isActive) continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                if (continuation.isActive) continuation.resume(response) else response.close()
            }
        })
    }

    private companion object {
        val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()
    }
}
