package com.gaixianggeng.mimi.core.notifications

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.content.res.Configuration
import android.os.Build
import android.os.LocaleList
import android.os.SystemClock
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Locale

@RunWith(AndroidJUnit4::class)
class NotificationCenterDeviceTest {
    @Test
    fun channelNamesUseTheActiveApplicationLanguage() {
        val baseContext = ApplicationProvider.getApplicationContext<android.content.Context>()
        val configuration = Configuration(baseContext.resources.configuration).apply {
            setLocales(LocaleList(Locale.forLanguageTag("zh-CN")))
        }
        val context = baseContext.createConfigurationContext(configuration)
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.deleteNotificationChannel("codex_runs")
        manager.deleteNotificationChannel("codex_attention")

        NotificationCenter(context)

        assertEquals("Codex 运行", manager.getNotificationChannel("codex_runs").name.toString())
        assertEquals("Codex 需要处理", manager.getNotificationChannel("codex_attention").name.toString())
    }

    @Test
    fun notificationKindsUseExpectedChannelsCategoriesAndSafeRouteIntents() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        if (Build.VERSION.SDK_INT >= 33) {
            InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(
                context.packageName,
                Manifest.permission.POST_NOTIFICATIONS,
            )
        }
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.cancelAll()
        val center = NotificationCenter(context)
        listOf(
            Triple(RuntimeNotificationKind.Completion, "Completed", "thread-completed"),
            Triple(RuntimeNotificationKind.Failure, "Failed", "thread-failed"),
            Triple(RuntimeNotificationKind.Approval, "Approval", "thread-approval"),
            Triple(RuntimeNotificationKind.Reminder, "Reminder", "thread-reminder"),
        ).forEach { (kind, title, threadId) ->
            center.post(kind, title, "$title body", "profile-1", "project-1", threadId)
        }
        val deadline = SystemClock.elapsedRealtime() + 2_000L
        var notifications = manager.activeNotifications.map { it.notification }
        while (notifications.size < 4 && SystemClock.elapsedRealtime() < deadline) {
            SystemClock.sleep(50L)
            notifications = manager.activeNotifications.map { it.notification }
        }
        assertEquals("All notification kinds should be posted", 4, notifications.size)
        val byTitle = notifications.associateBy { it.extras.getCharSequence(Notification.EXTRA_TITLE).toString() }

        assertEquals("codex_runs", requireNotNull(byTitle["Completed"]).channelId)
        assertEquals(Notification.CATEGORY_MESSAGE, byTitle.getValue("Completed").category)
        assertEquals("Completed body", byTitle.getValue("Completed").extras.getCharSequence(Notification.EXTRA_TEXT).toString())
        assertEquals("codex_attention", requireNotNull(byTitle["Failed"]).channelId)
        assertEquals(Notification.CATEGORY_MESSAGE, byTitle.getValue("Failed").category)
        assertEquals("codex_attention", requireNotNull(byTitle["Approval"]).channelId)
        assertEquals(Notification.CATEGORY_STATUS, byTitle.getValue("Approval").category)
        assertEquals("codex_runs", requireNotNull(byTitle["Reminder"]).channelId)
        assertEquals(Notification.CATEGORY_REMINDER, byTitle.getValue("Reminder").category)
        assertTrue(notifications.all { it.contentIntent != null })
        manager.cancelAll()
    }
}
