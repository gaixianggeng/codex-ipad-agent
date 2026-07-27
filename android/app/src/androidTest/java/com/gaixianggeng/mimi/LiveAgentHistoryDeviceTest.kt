package com.gaixianggeng.mimi

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.gaixianggeng.mimi.app.AppContainer
import com.gaixianggeng.mimi.core.model.ConversationRole
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Read-only validation against the profile already paired on the device.
 *
 * The test never starts a turn or invokes a workspace action. It verifies that the Android
 * app-server projection can recover structured activity from real persisted conversations.
 */
@RunWith(AndroidJUnit4::class)
class LiveAgentHistoryDeviceTest {
    @Test
    fun storedProfileProjectsStructuredActivityFromLiveHistory() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val container = AppContainer(context)
        val profiles = container.profileStore.profiles.first()
        val activeProfileId = container.profileStore.activeProfileId.first()
        val profile = profiles.firstOrNull { it.id == activeProfileId } ?: profiles.firstOrNull()
        assumeTrue("A paired profile is required", profile != null)
        val token = container.credentialStore.read(requireNotNull(profile).id)
        assumeTrue("The paired profile must have an encrypted credential", !token.isNullOrBlank())

        val appServer = container.newAppServerClient()
        var inspectedThreads = 0
        var projectedMessages = 0
        var projectedActivities = 0
        var projectedContextTasks = 0
        var projectedContextSources = 0
        try {
            withTimeout(90_000) {
                container.apiClient.ready(profile.endpoint, requireNotNull(token))
                val projects = container.apiClient.projects(profile.endpoint, token)
                projects.firstOrNull()?.let { project ->
                    container.apiClient.gitStatus(profile.endpoint, token, project.path)
                }
                appServer.connect(profile.endpoint, token)

                projects.take(6).forEach { project ->
                    if (projectedActivities > 0) return@forEach
                    val threads = appServer.listThreads(project.path, limit = 30).threads
                        .filter { it.runtimeProvider == "codex" }
                        .take(12)
                    projectedContextSources += threads.sumOf { it.context?.sources?.size ?: 0 }
                    for (thread in threads) {
                        inspectedThreads += 1
                        var cursor: String? = null
                        var pageCount = 0
                        while (pageCount < 3) {
                            val page = appServer.conversationPage(thread.id, cursor, limit = 50)
                            pageCount += 1
                            projectedMessages += page.messages.size
                            projectedActivities += page.messages.count {
                                it.role == ConversationRole.Activity && it.activity != null
                            }
                            projectedContextTasks += page.context?.tasks?.size ?: 0
                            cursor = page.nextCursor
                            if (projectedActivities > 0 || cursor == null) break
                        }
                        if (projectedActivities > 0) break
                    }
                }
            }
        } finally {
            appServer.close()
        }

        assertTrue("Expected at least one persisted Codex thread", inspectedThreads > 0)
        assertTrue("Expected persisted conversation messages", projectedMessages > 0)
        assertTrue("Expected at least one structured activity projection", projectedActivities > 0)
        assertTrue("Expected at least one projected session-context task", projectedContextTasks > 0)
        assertTrue("Expected at least one projected session source", projectedContextSources > 0)
    }
}
