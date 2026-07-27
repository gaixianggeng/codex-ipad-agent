package com.gaixianggeng.mimi

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.gaixianggeng.mimi.app.AppContainer
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LiveAgentProtocolDeviceTest {
    @Test
    fun androidClientCompletesLiveHandshakeAndSessionList() {
        runBlocking {
            val arguments = InstrumentationRegistry.getArguments()
            val endpoint = arguments.getString("liveEndpoint").orEmpty()
            val token = arguments.getString("liveToken").orEmpty()
            assumeTrue("Live endpoint and token are required", endpoint.isNotBlank() && token.isNotBlank())

            val container = AppContainer(ApplicationProvider.getApplicationContext())
            val appServer = container.newAppServerClient()
            var stage = "ready"
            try {
                withTimeout(45_000) {
                    container.apiClient.ready(endpoint, token)
                    stage = "projects"
                    val projects = container.apiClient.projects(endpoint, token)
                    stage = "app-server config"
                    container.apiClient.appServerConfig(endpoint, token)
                    stage = "app-server connect"
                    appServer.connect(endpoint, token)
                    stage = "thread list"
                    projects.firstOrNull()?.let { appServer.listThreads(it.path) }
                }
            } catch (error: Throwable) {
                throw AssertionError(
                    "Live Android protocol failed at $stage: " +
                        (error.message ?: error::class.java.simpleName),
                    error,
                )
            } finally {
                appServer.close()
            }
        }
    }
}
