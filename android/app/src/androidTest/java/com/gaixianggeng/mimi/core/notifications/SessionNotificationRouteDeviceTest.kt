package com.gaixianggeng.mimi.core.notifications

import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SessionNotificationRouteDeviceTest {
    @Test
    fun currentRouteRoundTripsVersionedBoundedIdentifiers() {
        val route = requireNotNull(SessionNotificationRoute.current(" profile ", "project", "thread"))
        val uri = route.toUri()

        assertEquals("mimiremote", uri.scheme)
        assertEquals("open", uri.authority)
        assertEquals("1", uri.getQueryParameter("version"))
        assertEquals("profile", uri.getQueryParameter("profile_id"))
        assertEquals(setOf("version", "profile_id", "project_id", "thread_id"), uri.queryParameterNames)
        assertTrue("Route must not carry credentials", "token" !in uri.queryParameterNames)
        assertTrue("Route must not carry message content", "body" !in uri.queryParameterNames)
        assertTrue("Route must not carry workspace paths", "cwd" !in uri.queryParameterNames)
        assertEquals(route, SessionNotificationRoute.parse(uri))
    }

    @Test
    fun parserRejectsMissingFutureOrMalformedMetadata() {
        val valid = "mimiremote://open?version=1&profile_id=p&project_id=j&thread_id=t"

        assertNull(SessionNotificationRoute.parse(Uri.parse(valid.replace("version=1&", ""))))
        assertNull(SessionNotificationRoute.parse(Uri.parse(valid.replace("version=1", "version=2"))))
        assertNull(SessionNotificationRoute.parse(Uri.parse(valid.replace("thread_id=t", "thread_id="))))
        assertNull(SessionNotificationRoute.parse(Uri.parse(valid.replace("mimiremote://open", "https://open"))))
        assertNull(SessionNotificationRoute.parse(Uri.parse(valid.replace("mimiremote://open", "mimiremote://pair"))))
    }

    @Test
    fun builderRejectsIdentifiersOutsideTheContract() {
        assertNull(SessionNotificationRoute.current("", "project", "thread"))
        assertNull(SessionNotificationRoute.current("profile", " ", "thread"))
        assertNull(SessionNotificationRoute.current("profile", "project", "x".repeat(513)))
        assertTrue(SessionNotificationRoute.current("x".repeat(512), "project", "thread") != null)
    }
}
