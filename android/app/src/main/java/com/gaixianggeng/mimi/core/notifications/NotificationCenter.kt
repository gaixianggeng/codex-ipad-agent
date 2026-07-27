package com.gaixianggeng.mimi.core.notifications

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.gaixianggeng.mimi.MainActivity
import com.gaixianggeng.mimi.R

enum class RuntimeNotificationKind { Completion, Failure, Approval, Reminder }

class NotificationCenter(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    init {
        manager.createNotificationChannels(listOf(
            NotificationChannel(CHANNEL_RUNS, context.getString(R.string.notification_channel_runs), NotificationManager.IMPORTANCE_DEFAULT),
            NotificationChannel(CHANNEL_ATTENTION, context.getString(R.string.notification_channel_attention), NotificationManager.IMPORTANCE_HIGH),
        ))
    }

    fun post(
        kind: RuntimeNotificationKind,
        title: String,
        body: String,
        profileId: String,
        projectId: String,
        threadId: String,
    ) {
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val route = SessionNotificationRoute.current(profileId, projectId, threadId)?.toUri() ?: return
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = route
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            route.toString().hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val channel = if (kind == RuntimeNotificationKind.Completion || kind == RuntimeNotificationKind.Reminder) CHANNEL_RUNS else CHANNEL_ATTENTION
        val notification = NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_mimi)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setCategory(if (kind == RuntimeNotificationKind.Approval) NotificationCompat.CATEGORY_STATUS else if (kind == RuntimeNotificationKind.Reminder) NotificationCompat.CATEGORY_REMINDER else NotificationCompat.CATEGORY_MESSAGE)
            .build()
        manager.notify(route.toString().hashCode(), notification)
    }

    private companion object {
        const val CHANNEL_RUNS = "codex_runs"
        const val CHANNEL_ATTENTION = "codex_attention"
    }
}
