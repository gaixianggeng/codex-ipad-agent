package com.gaixianggeng.mimi.core.network

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import com.gaixianggeng.mimi.core.model.GitActionKind

class AgentApiClientTest {
    private lateinit var server: MockWebServer
    private lateinit var client: AgentApiClient

    @Before
    fun setUp() {
        server = MockWebServer().also { it.start() }
        client = AgentApiClient(OkHttpClient.Builder().followRedirects(false).build(), Json { ignoreUnknownKeys = true })
    }

    @After
    fun tearDown() = server.shutdown()

    @Test
    fun `authorized file preview uses bounded read endpoint shape`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"path":"/repo/readme.txt","name":"readme.txt","content_type":"text/plain","size":5,"content_base64":"aGVsbG8="}"""
        ))
        val response = client.readFile(server.url("/").toString(), "secret-token", "/repo/readme.txt")
        val request = server.takeRequest()
        assertEquals("/api/files/read", request.path)
        assertEquals("Bearer secret-token", request.getHeader("Authorization"))
        assertTrue(request.body.readUtf8().contains("/repo/readme.txt"))
        assertEquals("readme.txt", response.name)
    }

    @Test
    fun `projects decode the server response envelope`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"projects":[{"id":"project-1","name":"Mimi","path":"/repo/mimi"}]}"""
        ))

        val projects = client.projects(server.url("/").toString(), "secret-token")
        val request = server.takeRequest()

        assertEquals("/api/projects", request.path)
        assertEquals("Bearer secret-token", request.getHeader("Authorization"))
        assertEquals("project-1", projects.single().id)
        assertEquals("/repo/mimi", projects.single().path)
    }

    @Test
    fun `history media uses an encoded opaque id and authenticated get`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"path":"history","name":"image.png","content_type":"image/png","size":3,"content_base64":"AAEC"}"""
        ))

        client.readHistoryMedia(server.url("/").toString(), "token", "media id/one")
        val request = server.takeRequest()

        assertEquals("/api/app-server/history-media/media%20id%2Fone", request.path)
        assertEquals("Bearer token", request.getHeader("Authorization"))
        assertEquals("GET", request.method)
    }

    @Test
    fun `app server config exposes only declared runtime channels`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"gateway_ws_url":"ws://host/api/app-server/ws","runtime":{},"projects":[],"policy":{},"channels":[{"id":"claude","runtime_id":"claude","title":"Claude Code","provider":"anthropic","gateway_available":true,"experimental":true}]}"""
        ))

        val config = client.appServerConfig(server.url("/").toString(), "token")
        val request = server.takeRequest()

        assertEquals("/api/app-server/config", request.path)
        assertEquals("claude", config.channels.single().runtimeId)
        assertTrue(config.channels.single().gatewayAvailable)
    }

    @Test
    fun `connection diagnostics decode gateway and tailscale path without sensitive payloads`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"generated_at":"2026-07-23T00:00:00Z","app_server_gateway":{"total_connections":8,"active_connections":1,"failed_upstream_dials":2,"upstream_dial_ms_max":91,"policy_errors":0},"hints":["inspect upstream"]}"""
        ))
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"kind":"derp","observed_at":"2026-07-23T00:00:01Z","relay_region":"hkg"}"""
        ))

        val relay = client.relayDiagnostics(server.url("/").toString(), "token")
        val relayRequest = server.takeRequest()
        val tailscale = client.tailscaleNetworkPath(server.url("/").toString(), "token")
        val tailscaleRequest = server.takeRequest()

        assertEquals("/api/diagnostics/relay", relayRequest.path)
        assertEquals("GET", relayRequest.method)
        assertEquals(2, relay.appServerGateway.failedUpstreamDials)
        assertEquals("/api/diagnostics/tailscale-path", tailscaleRequest.path)
        assertEquals("derp", tailscale.kind)
        assertEquals("hkg", tailscale.relayRegion)
    }

    @Test
    fun `developer history diagnostics are authenticated bounded and project scoped`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"sessions":[],"summary":{"visible":0}}"""
        ))

        val response = client.codexHistoryDiagnostics(server.url("/").toString(), "secret", "project id/one", 999)
        val request = server.takeRequest()

        assertEquals("/api/debug/codex-history?limit=200&project_id=project%20id%2Fone", request.path)
        assertEquals("Bearer secret", request.getHeader("Authorization"))
        assertTrue(response.containsKey("summary"))
    }

    @Test
    fun `developer history diagnostics reject missing or oversized project scope before network`() = runTest {
        val missing = runCatching {
            client.codexHistoryDiagnostics(server.url("/").toString(), "secret", "   ")
        }
        val oversized = runCatching {
            client.codexHistoryDiagnostics(server.url("/").toString(), "secret", "x".repeat(513))
        }

        assertTrue(missing.exceptionOrNull() is IllegalArgumentException)
        assertTrue(oversized.exceptionOrNull() is IllegalArgumentException)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `voice transcription sends base64 contract and decodes result`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"text":"transcribed words","model":"codex-session-transcribe"}"""
        ))
        val response = client.transcribeVoice(server.url("/").toString(), "token", "voice.m4a", "audio/mp4", "AAEC")
        val request = server.takeRequest()
        assertEquals("/api/voice/transcribe", request.path)
        val body = request.body.readUtf8()
        assertTrue(body.contains("\"audio_base64\":\"AAEC\""))
        assertTrue(body.contains("\"content_type\":\"audio/mp4\""))
        assertEquals("transcribed words", response.text)
    }

    @Test
    fun `worktree cleanup preview is dry and decodes protected candidates`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(cleanupResponseJson))

        val response = client.previewWorktreeCleanup(server.url("/").toString(), "token")
        val request = server.takeRequest()

        assertEquals("/api/worktrees/cleanup", request.path)
        assertEquals("{}", request.body.readUtf8())
        assertEquals("plan-123", response.planId)
        assertEquals(listOf("/repo/wt-old"), response.candidatePaths)
        assertEquals(listOf("dirty"), response.worktrees.last().blockers)
    }

    @Test
    fun `worktree cleanup execution sends exact preview plan and paths`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(cleanupResponseJson))

        client.executeWorktreeCleanup(server.url("/").toString(), "token", listOf("/repo/wt-old"), "plan-123")
        val request = server.takeRequest()
        val body = request.body.readUtf8()

        assertEquals("/api/worktrees/cleanup", request.path)
        assertTrue(body.contains("\"dry_run\":false"))
        assertTrue(body.contains("\"confirm\":true"))
        assertTrue(body.contains("\"paths\":[\"/repo/wt-old\"]"))
        assertTrue(body.contains("\"plan_id\":\"plan-123\""))
    }

    @Test
    fun `worktree cleanup execution rejects altered or unbounded preview data before network`() = runTest {
        val empty = runCatching {
            client.executeWorktreeCleanup(server.url("/").toString(), "token", emptyList(), "plan")
        }
        val duplicate = runCatching {
            client.executeWorktreeCleanup(server.url("/").toString(), "token", listOf("/wt", "/wt"), "plan")
        }
        val alteredPath = runCatching {
            client.executeWorktreeCleanup(server.url("/").toString(), "token", listOf(" /wt "), "plan")
        }
        val invalidPlan = runCatching {
            client.executeWorktreeCleanup(server.url("/").toString(), "token", listOf("/wt"), " ")
        }

        listOf(empty, duplicate, alteredPath, invalidPlan).forEach {
            assertTrue(it.exceptionOrNull() is IllegalArgumentException)
        }
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `worktree branch suggestions preserve default and current metadata`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"path":"/repo","default_base":"origin/main","current_branch":"feature/android","branches":[{"name":"origin/main","kind":"remote","is_default":true},{"name":"feature/android","kind":"local","is_current":true}]}"""
        ))

        val response = client.listWorktreeBranches(server.url("/").toString(), "token", "/repo")
        val request = server.takeRequest()

        assertEquals("/api/worktrees/branches", request.path)
        assertEquals("{\"path\":\"/repo\"}", request.body.readUtf8())
        assertEquals("origin/main", response.defaultBase)
        assertTrue(response.branches.first().isDefault)
        assertTrue(response.branches.last().isCurrent)
    }

    @Test
    fun `worktree create and delete normalize input and never expose force delete`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"workspace":{"id":"wt","name":"Feature","path":"/repo/wt"},"worktree":{"path":"/repo/wt","repository_path":"/repo","base":"main","root_project_id":"root","root_project_name":"Repo","root_project_path":"/repo"}}"""
        ))
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"deleted_path":"/repo/wt","worktrees":[]}"""
        ))

        client.createWorktree(server.url("/").toString(), "token", " /repo ", " feature ", " main ")
        val create = server.takeRequest()
        val createBody = Json.parseToJsonElement(create.body.readUtf8()).jsonObject
        client.deleteWorktree(server.url("/").toString(), "token", " /repo/wt ")
        val delete = server.takeRequest()
        val deleteBody = Json.parseToJsonElement(delete.body.readUtf8()).jsonObject

        assertEquals("/api/worktrees/create", create.path)
        assertEquals("/repo", createBody.getValue("path").jsonPrimitive.content)
        assertEquals("feature", createBody.getValue("name").jsonPrimitive.content)
        assertEquals("main", createBody.getValue("base").jsonPrimitive.content)
        assertEquals("/api/worktrees/delete", delete.path)
        assertEquals("/repo/wt", deleteBody.getValue("path").jsonPrimitive.content)
        assertEquals(false, deleteBody.getValue("force").jsonPrimitive.content.toBoolean())
    }

    @Test
    fun `worktree mutations reject unbounded input before network`() = runTest {
        val blankPath = runCatching {
            client.createWorktree(server.url("/").toString(), "token", " ", null, null)
        }
        val longName = runCatching {
            client.createWorktree(server.url("/").toString(), "token", "/repo", "x".repeat(257), null)
        }
        val longBase = runCatching {
            client.createWorktree(server.url("/").toString(), "token", "/repo", null, "x".repeat(513))
        }
        val longDelete = runCatching {
            client.deleteWorktree(server.url("/").toString(), "token", "x".repeat(4097))
        }

        listOf(blankPath, longName, longBase, longDelete).forEach {
            assertTrue(it.exceptionOrNull() is IllegalArgumentException)
        }
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `doctor and capability diagnostics keep secrets out of request shape`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"ok":false,"version":"dev","listen":"127.0.0.1:8787","checks":[{"name":"codex","ok":false,"level":"error","message":"missing","fix":"install Codex"}]}"""
        ))
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"path":"/repo","skills":[],"mcp_servers":[{"name":"docs","scope":"repo","config_path":"/repo/.codex/config.toml","transport":"http","enabled":true,"status":"configured"}]}"""
        ))

        val doctor = client.doctor(server.url("/").toString(), "token")
        val doctorRequest = server.takeRequest()
        val capabilities = client.capabilities(server.url("/").toString(), "token", "/repo")
        val capabilityRequest = server.takeRequest()

        assertEquals("/api/doctor", doctorRequest.path)
        assertEquals("install Codex", doctor.checks.single().fix)
        assertEquals("/api/capabilities/list", capabilityRequest.path)
        assertEquals("{\"path\":\"/repo\"}", capabilityRequest.body.readUtf8())
        assertEquals("docs", capabilities.mcpServers.single().name)
    }

    @Test
    fun `directory browser and workspace resolution use server authorized contracts`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"path":"/repo","parent_path":"/","entries":[{"name":"src","path":"/repo/src","is_dir":true,"can_open":true,"can_browse":true,"can_preview":false}]}"""
        ))
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"workspace":{"id":"workspace-1","name":"Repo","path":"/repo"}}"""
        ))

        val listing = client.listDirectories(server.url("/").toString(), "token", "/repo")
        val listRequest = server.takeRequest()
        val workspace = client.resolveWorkspace(server.url("/").toString(), "token", "/repo")
        val resolveRequest = server.takeRequest()

        assertEquals("/api/directories/list", listRequest.path)
        assertEquals("/repo/src", listing.entries.single().path)
        assertEquals("/api/workspaces/resolve", resolveRequest.path)
        assertEquals("workspace-1", workspace.id)
    }

    @Test
    fun `git patch action sends only the selected patch`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"path":"/repo","is_repository":true,"files":[]}"""
        ))
        val patch = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n"

        client.gitPatchAction(server.url("/").toString(), "token", "/repo", GitActionKind.StagePatch, patch)
        val request = server.takeRequest()
        val body = request.body.readUtf8()

        assertEquals("/api/git/action", request.path)
        assertTrue(body.contains("\"action\":\"stage_patch\""))
        assertTrue(body.contains("@@ -1 +1 @@"))
    }

    @Test
    fun `git file action sends exact unique file selection`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"path":"/repo","is_repository":true,"files":[]}"""
        ))

        client.gitAction(
            server.url("/").toString(),
            "token",
            "/repo",
            GitActionKind.Unstage,
            listOf("README.md", "app/src/Main.kt"),
        )
        val request = server.takeRequest()
        val body = request.body.readUtf8()

        assertEquals("/api/git/action", request.path)
        assertTrue(body.contains("\"action\":\"unstage\""))
        assertTrue(body.contains("\"files\":[\"README.md\",\"app/src/Main.kt\"]"))
        assertTrue(!body.contains("\"patch\""))
    }

    @Test
    fun `git mutation rejects mismatched kinds duplicates and malformed patches before network`() = runTest {
        val wrongFileKind = runCatching {
            client.gitAction(server.url("/").toString(), "token", "/repo", GitActionKind.StagePatch, listOf("README.md"))
        }
        val duplicateFiles = runCatching {
            client.gitAction(server.url("/").toString(), "token", "/repo", GitActionKind.Stage, listOf("README.md", "README.md"))
        }
        val wrongPatchKind = runCatching {
            client.gitPatchAction(server.url("/").toString(), "token", "/repo", GitActionKind.Revert, "diff --git a/a b/a\n@@ -1 +1 @@\n-a\n+b\n")
        }
        val malformedPatch = runCatching {
            client.gitPatchAction(server.url("/").toString(), "token", "/repo", GitActionKind.RevertPatch, "@@ -1 +1 @@\n-a\n+b\n")
        }

        listOf(wrongFileKind, duplicateFiles, wrongPatchKind, malformedPatch).forEach {
            assertTrue(it.exceptionOrNull() is IllegalArgumentException)
        }
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `publish endpoints preserve explicit confirmation and non force push schema`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"path":"/repo","remote":"origin","branch":"main","status":{"path":"/repo","is_repository":true}}"""
        ))
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"path":"/repo","remote":"origin","branch":"main","message":"Ship Android","committed":true,"status":{"path":"/repo","is_repository":true}}"""
        ))
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"path":"/repo","capability":{"is_ios_project":true,"available":true,"reason":"ready"},"job":{"id":"job-1","state":"running","started_at":"2026-07-24T00:00:00Z"}}"""
        ))

        client.gitPush(server.url("/").toString(), "token", "/repo")
        val pushBody = server.takeRequest().body.readUtf8()
        client.gitQuickPublish(server.url("/").toString(), "token", "/repo", "Ship Android", confirmed = true)
        val publishBody = server.takeRequest().body.readUtf8()
        client.gitTestFlightRun(server.url("/").toString(), "token", "/repo", "Verify pairing", confirmed = true)
        val testFlightBody = server.takeRequest().body.readUtf8()

        assertTrue(!pushBody.contains("force"))
        assertTrue(publishBody.contains("\"confirmed\":true"))
        assertTrue(testFlightBody.contains("\"confirmed\":true"))
    }

    @Test
    fun `publish endpoints reject unconfirmed and oversized requests before network`() = runTest {
        val unconfirmedPublish = runCatching {
            client.gitQuickPublish(server.url("/").toString(), "token", "/repo", "Ship", confirmed = false)
        }
        val unconfirmedTestFlight = runCatching {
            client.gitTestFlightRun(server.url("/").toString(), "token", "/repo", "Verify", confirmed = false)
        }
        val oversizedCommit = runCatching {
            client.gitCommit(server.url("/").toString(), "token", "/repo", "x".repeat(501))
        }
        val oversizedPullRequest = runCatching {
            client.gitCreatePullRequest(server.url("/").toString(), "token", "/repo", "x".repeat(257), "", false)
        }

        listOf(unconfirmedPublish, unconfirmedTestFlight, oversizedCommit, oversizedPullRequest).forEach {
            assertTrue(it.exceptionOrNull() is IllegalArgumentException)
        }
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `allowlisted action run preserves explicit confirmation`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(
            """{"id":"tests","name":"Tests","path":"/repo","working_dir":"/repo","command":"gradle","args":["test"],"success":true,"exit_code":0,"duration_ms":120}"""
        ))

        client.runCommandAction(server.url("/").toString(), "token", "/repo", "tests", true)
        val request = server.takeRequest()

        assertEquals("/api/actions/run", request.path)
        assertTrue(request.body.readUtf8().contains("\"confirmed\":true"))
    }

    @Test
    fun `allowlisted action endpoints reject missing or oversized ids before network`() = runTest {
        val missingPath = runCatching {
            client.commandActions(server.url("/").toString(), "token", " ")
        }
        val missingId = runCatching {
            client.runCommandAction(server.url("/").toString(), "token", "/repo", " ", false)
        }
        val oversizedId = runCatching {
            client.runCommandAction(server.url("/").toString(), "token", "/repo", "x".repeat(257), true)
        }
        val rewrittenId = runCatching {
            client.runCommandAction(server.url("/").toString(), "token", "/repo", " tests ", true)
        }

        listOf(missingPath, missingId, oversizedId, rewrittenId).forEach {
            assertTrue(it.exceptionOrNull() is IllegalArgumentException)
        }
        assertEquals(0, server.requestCount)
    }

    private val cleanupResponseJson = """
        {
          "dry_run": true,
          "plan_id": "plan-123",
          "policy": {"auto_delete": false, "candidate_after_days": 30, "keep_latest_per_project": 3},
          "generated_at": "2026-07-23T08:00:00Z",
          "candidate_paths": ["/repo/wt-old"],
          "worktrees": [
            {
              "workspace": {"id":"w1","name":"old","path":"/repo/wt-old"},
              "worktree": {"path":"/repo/wt-old","repository_path":"/repo","base":"main","git_state":"clean","root_project_id":"p1","root_project_name":"Repo","root_project_path":"/repo"},
              "eligible": true
            },
            {
              "workspace": {"id":"w2","name":"dirty","path":"/repo/wt-dirty"},
              "worktree": {"path":"/repo/wt-dirty","repository_path":"/repo","base":"main","git_state":"dirty","dirty":true,"root_project_id":"p1","root_project_name":"Repo","root_project_path":"/repo"},
              "eligible": false,
              "blockers": ["dirty"]
            }
          ]
        }
    """.trimIndent()
}
