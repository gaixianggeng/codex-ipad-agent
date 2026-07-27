package com.gaixianggeng.mimi.core.notifications

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.gaixianggeng.mimi.MimiApplication
import com.gaixianggeng.mimi.R
import com.gaixianggeng.mimi.core.model.SessionReminder
import com.gaixianggeng.mimi.core.model.SessionReminderPolicy
import kotlinx.coroutines.runBlocking

class SessionReminderScheduler(private val context: Context) {
    private val alarmManager = context.getSystemService(AlarmManager::class.java)

    fun schedule(reminder: SessionReminder) {
        SessionReminderPolicy.validate(reminder)
        alarmManager.setAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            reminder.fireAtEpochMillis,
            pendingIntent(reminder.profileId, reminder.projectId, reminder.threadId),
        )
    }

    fun cancel(profileId: String, projectId: String, threadId: String) {
        require(SessionReminderPolicy.validRoute(profileId, projectId, threadId))
        val pending = pendingIntent(profileId, projectId, threadId)
        alarmManager.cancel(pending)
        pending.cancel()
    }

    private fun pendingIntent(profileId: String, projectId: String, threadId: String): PendingIntent {
        val route = Uri.Builder().scheme("mimiremote").authority("reminder")
            .appendQueryParameter("profile_id", profileId)
            .appendQueryParameter("project_id", projectId)
            .appendQueryParameter("thread_id", threadId)
            .build()
        val intent = Intent(context, SessionReminderReceiver::class.java).apply { data = route }
        return PendingIntent.getBroadcast(
            context,
            route.toString().hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

class SessionReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val route = intent.data ?: return
        val profileId = route.getQueryParameter("profile_id")?.takeIf(String::isNotBlank) ?: return
        val projectId = route.getQueryParameter("project_id")?.takeIf(String::isNotBlank) ?: return
        val threadId = route.getQueryParameter("thread_id")?.takeIf(String::isNotBlank) ?: return
        if (!SessionReminderPolicy.validRoute(profileId, projectId, threadId)) return
        val application = context.applicationContext as? MimiApplication ?: return
        val reminder = runBlocking {
            application.container.sessionReminderStore.consume(profileId, projectId, threadId)
        } ?: return
        application.container.notificationCenter.post(
            RuntimeNotificationKind.Reminder,
            context.getString(R.string.session_reminder_title),
            reminder.title,
            profileId,
            projectId,
            threadId,
        )
    }
}
