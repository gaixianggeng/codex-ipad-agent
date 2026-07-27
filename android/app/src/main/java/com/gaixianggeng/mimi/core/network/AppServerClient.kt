package com.gaixianggeng.mimi.core.network

import com.gaixianggeng.mimi.core.model.AgentThread
import com.gaixianggeng.mimi.core.model.ConversationPage
import com.gaixianggeng.mimi.core.model.ComposerSendMode
import com.gaixianggeng.mimi.core.model.ThreadPage
import com.gaixianggeng.mimi.core.model.ThreadSearchPage
import com.gaixianggeng.mimi.core.model.ModelOption
import com.gaixianggeng.mimi.core.model.SkillCapability
import com.gaixianggeng.mimi.core.model.PermissionMode
import com.gaixianggeng.mimi.core.model.ThreadGoal
import com.gaixianggeng.mimi.core.model.ThreadGoalStatus
import com.gaixianggeng.mimi.core.model.ReviewStartResult
import com.gaixianggeng.mimi.core.model.ReviewTargetKind
import com.gaixianggeng.mimi.core.model.RuntimeRoutingPolicy
import com.gaixianggeng.mimi.core.model.ImageAttachment
import com.gaixianggeng.mimi.core.model.RateLimitSummary
import java.io.Closeable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

data class AppServerEvent(val method: String, val params: JsonObject, val requestId: JsonElement? = null)

internal fun appServerWebSocketUrl(
    endpoint: String,
    threadId: String?,
    runtimeProvider: String,
): String {
    val webSocketBase = when {
        endpoint.startsWith("https://") -> "wss://${endpoint.removePrefix("https://")}"
        endpoint.startsWith("http://") -> "ws://${endpoint.removePrefix("http://")}"
        else -> throw AppServerException("Connection endpoint is invalid")
    }
    val runtime = RuntimeRoutingPolicy.normalize(runtimeProvider)
    val query = buildList {
        threadId?.takeIf(String::isNotBlank)?.let {
            add("thread_id=${java.net.URLEncoder.encode(it, Charsets.UTF_8.name())}")
        }
        if (runtime != RuntimeRoutingPolicy.Codex) add("runtime=$runtime")
    }.joinToString("&").let { if (it.isEmpty()) "" else "?$it" }
    return "$webSocketBase/api/app-server/ws$query"
}

internal fun structuredTurnInput(
    text: String,
    skills: List<SkillCapability>,
    images: List<ImageAttachment>,
): JsonArray = buildJsonArray {
    if (text.isNotBlank()) add(buildJsonObject {
        put("type", JsonPrimitive("text"))
        put("text", JsonPrimitive(text))
        put("text_elements", buildJsonArray {})
    })
    images.forEach { attachment -> add(buildJsonObject {
        put("type", JsonPrimitive("image"))
        put("url", JsonPrimitive(attachment.dataUrl))
        put("detail", JsonPrimitive("auto"))
    }) }
    skills.filter { it.enabled }.forEach { skill -> add(buildJsonObject {
        put("type", JsonPrimitive("skill"))
        put("name", JsonPrimitive(skill.name))
        put("path", JsonPrimitive(skill.path))
    }) }
}

internal fun turnSteerParams(
    threadId: String,
    expectedTurnId: String,
    clientMessageId: String,
    text: String,
    skills: List<SkillCapability>,
    images: List<ImageAttachment>,
): JsonObject = buildJsonObject {
    put("threadId", JsonPrimitive(threadId))
    put("input", structuredTurnInput(text, skills, images))
    put("clientUserMessageId", JsonPrimitive(clientMessageId))
    put("expectedTurnId", JsonPrimitive(expectedTurnId))
}

internal fun turnStartParams(
    threadId: String,
    cwd: String,
    text: String,
    clientMessageId: String,
    model: String,
    effort: String?,
    skills: List<SkillCapability>,
    images: List<ImageAttachment>,
    permissionMode: PermissionMode,
    collaborationMode: ComposerSendMode,
): JsonObject {
    val resolvedModel = model.trim()
    val resolvedEffort = effort?.trim()?.takeIf(String::isNotEmpty)
    require(resolvedModel.isNotEmpty()) { "turn/start requires a resolved model" }
    return buildJsonObject {
        put("threadId", JsonPrimitive(threadId))
        put("cwd", JsonPrimitive(cwd))
        put("input", structuredTurnInput(text, skills, images))
        put("clientUserMessageId", JsonPrimitive(clientMessageId))
        put("model", JsonPrimitive(resolvedModel))
        resolvedEffort?.let { put("effort", JsonPrimitive(it)) }
        put("approvalPolicy", JsonPrimitive(permissionMode.approvalPolicy))
        put("approvalsReviewer", JsonPrimitive(permissionMode.approvalsReviewer))
        put("sandboxPolicy", buildJsonObject {
            put("type", JsonPrimitive(permissionMode.turnSandboxType))
            if (permissionMode.turnSandboxType == "workspaceWrite") {
                put("writableRoots", buildJsonArray { add(JsonPrimitive(cwd)) })
                put("excludeTmpdirEnvVar", JsonPrimitive(false))
                put("excludeSlashTmp", JsonPrimitive(false))
            }
            put("networkAccess", JsonPrimitive(false))
        })
        put("collaborationMode", buildJsonObject {
            put("mode", JsonPrimitive(collaborationMode.wireName))
            put("settings", buildJsonObject {
                if (resolvedEffort != null) {
                    put("reasoning_effort", JsonPrimitive(resolvedEffort))
                } else {
                    put("reasoning_effort", JsonNull)
                }
                put("developer_instructions", JsonNull)
                put("model", JsonPrimitive(resolvedModel))
            })
        })
    }
}

internal fun threadGoalSetParams(
    threadId: String,
    objective: String? = null,
    status: ThreadGoalStatus? = null,
    tokenBudget: Long? = null,
): JsonObject {
    val normalizedThreadId = threadId.trim()
    require(normalizedThreadId.isNotEmpty()) { "Thread id cannot be empty" }
    require(objective != null || status != null || tokenBudget != null) { "Goal update cannot be empty" }
    val normalizedObjective = objective?.trim()
    if (normalizedObjective != null) {
        require(normalizedObjective.isNotEmpty()) { "Goal objective cannot be empty" }
        require(normalizedObjective.toByteArray().size <= 8_192) { "Goal objective is too long" }
    }
    require(tokenBudget == null || tokenBudget > 0) { "Token budget must be greater than zero" }
    return buildJsonObject {
        put("threadId", JsonPrimitive(normalizedThreadId))
        normalizedObjective?.let { put("objective", JsonPrimitive(it)) }
        status?.let { put("status", JsonPrimitive(it.wireName)) }
        tokenBudget?.let { put("tokenBudget", JsonPrimitive(it)) }
    }
}

sealed interface AppServerStatus {
    data object Connecting : AppServerStatus
    data object Connected : AppServerStatus
    data object Suspended : AppServerStatus
    data class Disconnected(val message: String, val credentialsInvalid: Boolean = false) : AppServerStatus
}

class AppServerException(message: String) : Exception(message)

/**
 * One ordered JSON-RPC connection to agentd's Codex app-server gateway.
 * Every inbound frame is consumed by one channel reader before it reaches state reducers.
 */
class AppServerClient(
    private val httpClient: OkHttpClient,
    private val json: Json,
) : Closeable {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val inbound = Channel<String>(Channel.UNLIMITED)
    private val ids = AtomicLong(1)
    private val pending = ConcurrentHashMap<String, CompletableDeferred<JsonElement?>>()
    private val _events = MutableSharedFlow<AppServerEvent>(extraBufferCapacity = 64)
    val events: SharedFlow<AppServerEvent> = _events.asSharedFlow()
    private val _statuses = MutableSharedFlow<AppServerStatus>(replay = 1, extraBufferCapacity = 8)
    val statuses: SharedFlow<AppServerStatus> = _statuses.asSharedFlow()

    @Volatile private var socket: WebSocket? = null
    @Volatile private var opened = CompletableDeferred<Unit>()
    @Volatile private var terminalError: Throwable? = null
    @Volatile private var runtimeProvider: String = "codex"
    @Volatile private var recencySortUnavailable: Boolean = false

    init {
        scope.launch {
            for (text in inbound) handleFrame(text)
        }
    }

    suspend fun connect(endpoint: String, token: String, threadId: String? = null, runtimeProvider: String = "codex") {
        _statuses.emit(AppServerStatus.Connecting)
        closeSocketOnly()
        val normalized = (EndpointPolicy.assess(endpoint) as? EndpointAssessment.Allowed)?.normalizedEndpoint
            ?: throw AppServerException("Connection endpoint is not allowed")
        opened = CompletableDeferred()
        terminalError = null
        this.runtimeProvider = RuntimeRoutingPolicy.normalize(runtimeProvider)
        recencySortUnavailable = false
        val request = Request.Builder()
            .url(appServerWebSocketUrl(normalized, threadId, this.runtimeProvider))
            .header("Authorization", "Bearer $token")
            .build()
        socket = httpClient.newWebSocket(request, Listener())
        withTimeout(TimeUnit.SECONDS.toMillis(20)) { opened.await() }
        request(
            "initialize",
            buildJsonObject {
                put("clientInfo", buildJsonObject {
                    put("name", JsonPrimitive("mimi_remote_android"))
                    put("title", JsonPrimitive("Mimi Remote Android"))
                    put("version", JsonPrimitive("0.1.0"))
                })
                put("capabilities", buildJsonObject {
                    put("experimentalApi", JsonPrimitive(true))
                    put("requestAttestation", JsonPrimitive(false))
                })
            },
        )
        notify("initialized", buildJsonObject {})
        _statuses.emit(AppServerStatus.Connected)
    }

    fun suspendConnection() {
        closeSocketOnly()
        val error = AppServerException("WebSocket suspended")
        terminalError = error
        completePending(error)
        _statuses.tryEmit(AppServerStatus.Suspended)
    }

    suspend fun listThreads(cwd: String, cursor: String? = null, limit: Int = 50): ThreadPage {
        val sortKey = if (runtimeProvider == "codex" && !recencySortUnavailable) {
            "recency_at"
        } else {
            "updated_at"
        }
        return try {
            val result = request(
                "thread/list",
                buildJsonObject {
                    put("cwd", JsonPrimitive(cwd))
                    put("limit", JsonPrimitive(limit.coerceIn(1, 50)))
                    cursor?.takeIf(String::isNotBlank)?.let { put("cursor", JsonPrimitive(it)) }
                    put("sortKey", JsonPrimitive(sortKey))
                    put("sortDirection", JsonPrimitive("desc"))
                    put("archived", JsonPrimitive(false))
                    put("useStateDbOnly", JsonPrimitive(true))
                },
            )?.jsonObject ?: return ThreadPage(emptyList(), null)
            AppServerProjection.threadPage(result, cwd, runtimeProvider)
        } catch (error: AppServerException) {
            if (sortKey == "recency_at" && error.isUnsupportedRecencySort()) {
                recencySortUnavailable = true
                listThreads(cwd, cursor, limit)
            } else {
                throw error
            }
        }
    }

    private fun AppServerException.isUnsupportedRecencySort(): Boolean {
        val detail = message.orEmpty().lowercase()
        return "recency_at" in detail ||
            ("sortkey" in detail && ("unsupported" in detail || "not supported" in detail)) ||
            ("sortkey" in detail && "unknown variant" in detail)
    }

    suspend fun searchThreads(query: String, cursor: String? = null, limit: Int = 50): ThreadSearchPage {
        val normalized = query.trim()
        require(normalized.isNotEmpty())
        val result = request("thread/search", buildJsonObject {
            put("searchTerm", JsonPrimitive(normalized))
            put("limit", JsonPrimitive(limit.coerceIn(1, 50)))
            cursor?.takeIf(String::isNotBlank)?.let { put("cursor", JsonPrimitive(it)) }
            put("sortKey", JsonPrimitive("updated_at"))
            put("sortDirection", JsonPrimitive("desc"))
            put("archived", JsonPrimitive(false))
        })?.jsonObject ?: return ThreadSearchPage(emptyList(), null)
        return AppServerProjection.threadSearchPage(result, runtimeProvider)
    }

    suspend fun setThreadName(threadId: String, name: String) {
        val normalized = name.trim()
        require(normalized.isNotEmpty())
        require(normalized.toByteArray().size <= 256) { "Session name cannot exceed 256 bytes" }
        request("thread/name/set", buildJsonObject {
            put("threadId", JsonPrimitive(threadId)); put("name", JsonPrimitive(normalized))
        })
    }

    suspend fun archiveThread(threadId: String) = threadAction("thread/archive", threadId)
    suspend fun unarchiveThread(threadId: String) = threadAction("thread/unarchive", threadId)
    suspend fun compactThread(threadId: String) = threadAction("thread/compact/start", threadId)

    suspend fun unsubscribeThread(threadId: String) {
        request("thread/unsubscribe", buildJsonObject { put("threadId", JsonPrimitive(threadId)) })
    }

    suspend fun threadGoal(threadId: String): ThreadGoal? {
        val result = request("thread/goal/get", buildJsonObject { put("threadId", JsonPrimitive(threadId)) })?.jsonObject
        return AppServerProjection.threadGoal(result)
    }

    suspend fun setThreadGoal(
        threadId: String,
        objective: String? = null,
        status: ThreadGoalStatus? = null,
        tokenBudget: Long? = null,
    ): ThreadGoal {
        val result = request(
            "thread/goal/set",
            threadGoalSetParams(threadId, objective, status, tokenBudget),
        )?.jsonObject
        return AppServerProjection.threadGoal(result) ?: throw AppServerException("thread/goal/set returned no goal")
    }

    suspend fun clearThreadGoal(threadId: String) {
        request("thread/goal/clear", buildJsonObject { put("threadId", JsonPrimitive(threadId)) })
    }

    suspend fun startReview(
        threadId: String,
        kind: ReviewTargetKind,
        value: String? = null,
        title: String? = null,
    ): ReviewStartResult {
        val target = when (kind) {
            ReviewTargetKind.UncommittedChanges -> buildJsonObject { put("type", JsonPrimitive("uncommittedChanges")) }
            ReviewTargetKind.BaseBranch -> {
                val branch = value?.trim()?.takeIf(String::isNotEmpty) ?: error("Base branch cannot be empty")
                require(branch.toByteArray().size <= 256) { "Base branch is too long" }
                buildJsonObject { put("type", JsonPrimitive("baseBranch")); put("branch", JsonPrimitive(branch)) }
            }
            ReviewTargetKind.Commit -> {
                val sha = value?.trim()?.takeIf { it.matches(Regex("[0-9a-fA-F]{7,64}")) }
                    ?: error("Commit must be a 7-64 character hexadecimal SHA")
                buildJsonObject {
                    put("type", JsonPrimitive("commit")); put("sha", JsonPrimitive(sha))
                    title?.trim()?.takeIf(String::isNotEmpty)?.let { put("title", JsonPrimitive(it.take(256))) }
                }
            }
        }
        val result = request("review/start", buildJsonObject {
            put("threadId", JsonPrimitive(threadId))
            put("target", target)
            put("delivery", JsonPrimitive("inline"))
        })?.jsonObject ?: throw AppServerException("review/start returned no result")
        val reviewThreadId = result.string("reviewThreadId") ?: throw AppServerException("review/start returned no thread id")
        return ReviewStartResult(reviewThreadId, (result["turn"] as? JsonObject)?.string("id"))
    }

    suspend fun forkThread(threadId: String, cwd: String, permissionMode: PermissionMode = PermissionMode.FullAccess): AgentThread {
        val result = request("thread/fork", buildJsonObject {
            put("threadId", JsonPrimitive(threadId))
            put("cwd", JsonPrimitive(cwd))
            put("approvalPolicy", JsonPrimitive(permissionMode.approvalPolicy))
            put("approvalsReviewer", JsonPrimitive(permissionMode.approvalsReviewer))
            put("sandbox", JsonPrimitive(permissionMode.threadSandbox))
        })?.jsonObject ?: throw AppServerException("thread/fork returned no result")
        val thread = (result["thread"] as? JsonObject) ?: result
        return AgentThread(
            id = thread.string("id") ?: throw AppServerException("thread/fork returned no thread id"),
            preview = thread.string("name") ?: thread.string("preview") ?: "Forked session",
            cwd = thread.string("cwd") ?: cwd,
            runtimeProvider = runtimeProvider,
        )
    }

    suspend fun modelOptions(): List<ModelOption> = AppServerProjection.modelOptions(request("model/list"))

    suspend fun skills(cwd: String): List<SkillCapability> {
        val result = request("skills/list", buildJsonObject {
            put("cwds", buildJsonArray { add(JsonPrimitive(cwd)) })
            put("forceReload", JsonPrimitive(true))
        })?.jsonObject ?: return emptyList()
        return AppServerProjection.skills(result, cwd)
    }

    suspend fun installedPlugins(cwd: String): List<com.gaixianggeng.mimi.core.model.PluginCapability> {
        val result = request("plugin/installed", buildJsonObject {
            put("cwds", buildJsonArray { add(JsonPrimitive(cwd)) })
        })?.jsonObject ?: return emptyList()
        return AppServerProjection.installedPlugins(result)
    }

    suspend fun rateLimits(): RateLimitSummary? = AppServerProjection.rateLimitSummary(
        request("account/rateLimits/read") as? JsonObject,
    )

    private suspend fun threadAction(method: String, threadId: String) {
        request(method, buildJsonObject { put("threadId", JsonPrimitive(threadId)) })
    }

    suspend fun startThread(cwd: String, permissionMode: PermissionMode = PermissionMode.FullAccess): AgentThread {
        val result = request(
            "thread/start",
            buildJsonObject {
                put("cwd", JsonPrimitive(cwd))
                put("approvalPolicy", JsonPrimitive(permissionMode.approvalPolicy))
                put("approvalsReviewer", JsonPrimitive(permissionMode.approvalsReviewer))
                put("sandbox", JsonPrimitive(permissionMode.threadSandbox))
                put("ephemeral", JsonPrimitive(false))
            },
        )?.jsonObject ?: throw AppServerException("thread/start returned no result")
        val thread = (result["thread"] as? JsonObject) ?: result
        return AgentThread(
            id = thread.string("id") ?: throw AppServerException("thread/start returned no thread id"),
            preview = thread.string("name") ?: thread.string("preview") ?: "New session",
            cwd = thread.string("cwd") ?: cwd,
            runtimeProvider = runtimeProvider,
        )
    }

    suspend fun resumeThread(threadId: String, cwd: String, permissionMode: PermissionMode = PermissionMode.FullAccess) {
        request(
            "thread/resume",
            buildJsonObject {
                put("threadId", JsonPrimitive(threadId))
                put("cwd", JsonPrimitive(cwd))
                put("approvalPolicy", JsonPrimitive(permissionMode.approvalPolicy))
                put("approvalsReviewer", JsonPrimitive(permissionMode.approvalsReviewer))
                put("sandbox", JsonPrimitive(permissionMode.threadSandbox))
                put("excludeTurns", JsonPrimitive(true))
            },
        )
    }

    suspend fun conversationPage(threadId: String, cursor: String? = null, limit: Int = 50): ConversationPage {
        val result = request(
            "thread/turns/list",
            buildJsonObject {
                put("threadId", JsonPrimitive(threadId))
                put("limit", JsonPrimitive(limit.coerceIn(1, 50)))
                cursor?.takeIf(String::isNotBlank)?.let { put("cursor", JsonPrimitive(it)) }
                put("sortDirection", JsonPrimitive("desc"))
                put("itemsView", JsonPrimitive("full"))
            },
        )?.jsonObject ?: return ConversationPage(emptyList(), null)
        return AppServerProjection.conversationPage(result, threadId)
    }

    suspend fun startTurn(
        threadId: String,
        cwd: String,
        text: String,
        clientMessageId: String,
        model: String? = null,
        effort: String? = null,
        skills: List<SkillCapability> = emptyList(),
        images: List<ImageAttachment> = emptyList(),
        permissionMode: PermissionMode = PermissionMode.FullAccess,
        collaborationMode: ComposerSendMode = ComposerSendMode.Standard,
    ): String? {
        require(text.isNotBlank() || images.isNotEmpty())
        val resolvedModel = model?.trim()?.takeIf(String::isNotEmpty)
            ?: throw AppServerException("turn/start requires a resolved model")
        val result = request(
            "turn/start",
            turnStartParams(
                threadId = threadId,
                cwd = cwd,
                text = text,
                clientMessageId = clientMessageId,
                model = resolvedModel,
                effort = effort,
                skills = skills,
                images = images,
                permissionMode = permissionMode,
                collaborationMode = collaborationMode,
            ),
        )
        return TurnLifecycleProjection.startResultTurnId(result)
    }

    suspend fun steerTurn(
        threadId: String,
        expectedTurnId: String,
        text: String,
        clientMessageId: String,
        skills: List<SkillCapability> = emptyList(),
        images: List<ImageAttachment> = emptyList(),
    ) {
        require(text.isNotBlank() || images.isNotEmpty())
        request("turn/steer", turnSteerParams(threadId, expectedTurnId, clientMessageId, text, skills, images))
    }

    suspend fun interruptTurn(threadId: String, turnId: String) {
        request("turn/interrupt", buildJsonObject {
            put("threadId", JsonPrimitive(threadId))
            put("turnId", JsonPrimitive(turnId))
        })
    }

    suspend fun respond(requestId: JsonElement, result: JsonElement) {
        send(buildJsonObject {
            put("id", requestId)
            put("result", result)
        })
    }

    suspend fun request(method: String, params: JsonObject? = null): JsonElement? {
        terminalError?.let { throw AppServerException(it.message ?: "WebSocket is disconnected") }
        val id = ids.getAndIncrement().toString()
        val deferred = CompletableDeferred<JsonElement?>()
        pending[id] = deferred
        try {
            send(buildJsonObject {
                put("id", JsonPrimitive(id.toLong()))
                put("method", JsonPrimitive(method))
                params?.let { put("params", it) }
            })
            return withTimeout(TimeUnit.SECONDS.toMillis(20)) { deferred.await() }
        } finally {
            pending.remove(id)
        }
    }

    private fun notify(method: String, params: JsonObject) {
        send(buildJsonObject {
            put("method", JsonPrimitive(method))
            put("params", params)
        })
    }

    private fun send(frame: JsonObject) {
        if (socket?.send(json.encodeToString(JsonObject.serializer(), frame)) != true) {
            throw AppServerException("WebSocket is not connected")
        }
    }

    private suspend fun handleFrame(text: String) {
        val frame = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
        val id = frame["id"]?.let(::idKey)
        val method = frame.string("method")
        if (id != null && method == null) {
            val deferred = pending[id] ?: return
            val error = frame["error"] as? JsonObject
            if (error != null) {
                deferred.completeExceptionally(AppServerException(error.string("message") ?: "app-server request failed"))
            } else {
                deferred.complete(frame["result"]?.takeUnless { it is JsonNull })
            }
            return
        }
        if (method != null) {
            _events.emit(AppServerEvent(method, (frame["params"] as? JsonObject) ?: JsonObject(emptyMap()), frame["id"]))
        }
    }

    private fun idKey(id: JsonElement): String? = (id as? JsonPrimitive)?.contentOrNull

    private fun failAll(error: Throwable, credentialsInvalid: Boolean = false) {
        terminalError = error
        completePending(error)
        if (!opened.isCompleted) opened.completeExceptionally(error)
        _statuses.tryEmit(AppServerStatus.Disconnected(error.message ?: "WebSocket disconnected", credentialsInvalid))
    }

    private fun completePending(error: Throwable) {
        pending.values.forEach { it.completeExceptionally(error) }
        pending.clear()
    }

    private fun closeSocketOnly() {
        socket?.close(1001, "Switching connection")
        socket = null
    }


    override fun close() {
        closeSocketOnly()
        failAll(AppServerException("WebSocket closed"))
        inbound.close()
        scope.cancel()
    }

    private inner class Listener : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            opened.complete(Unit)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            inbound.trySend(text)
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(code, reason)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            if (socket === webSocket) failAll(AppServerException("WebSocket closed ($code)"))
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            if (socket === webSocket) {
                val code = response?.code
                failAll(
                    AppServerException(response?.let { "WebSocket HTTP ${it.code}" } ?: t.message ?: "WebSocket failed"),
                    credentialsInvalid = code == 401 || code == 403,
                )
            }
        }
    }
}

private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
