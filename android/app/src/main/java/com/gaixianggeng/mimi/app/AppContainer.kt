package com.gaixianggeng.mimi.app

import android.content.Context
import androidx.annotation.StringRes
import com.gaixianggeng.mimi.core.network.AgentApiClient
import com.gaixianggeng.mimi.core.network.AppServerClient
import com.gaixianggeng.mimi.core.network.NetworkMonitor
import com.gaixianggeng.mimi.core.security.AndroidCredentialStore
import com.gaixianggeng.mimi.core.storage.ProfileStore
import com.gaixianggeng.mimi.core.storage.QueuedTurnStore
import com.gaixianggeng.mimi.core.storage.ComposerDraftStore
import com.gaixianggeng.mimi.core.storage.AppearanceStore
import com.gaixianggeng.mimi.core.storage.PinnedThreadStore
import com.gaixianggeng.mimi.core.storage.SessionReminderStore
import com.gaixianggeng.mimi.core.notifications.SessionReminderScheduler
import com.gaixianggeng.mimi.core.media.ImageAttachmentEncoder
import com.gaixianggeng.mimi.core.media.VoiceRecorder
import com.gaixianggeng.mimi.core.media.DeviceSpeechTranscriber
import android.net.Uri
import android.util.Base64
import com.gaixianggeng.mimi.core.model.FileReadResponse
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.gaixianggeng.mimi.core.notifications.NotificationCenter
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

class AppContainer(private val context: Context) {
    fun string(@StringRes resourceId: Int, vararg formatArgs: Any): String =
        context.getString(resourceId, *formatArgs)

    val json: Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        encodeDefaults = true
    }

    val httpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(45, TimeUnit.SECONDS)
        .writeTimeout(45, TimeUnit.SECONDS)
        .followRedirects(false)
        .followSslRedirects(false)
        .build()

    val apiClient = AgentApiClient(httpClient, json)
    fun newAppServerClient() = AppServerClient(httpClient, json)
    val credentialStore = AndroidCredentialStore(context)
    val profileStore = ProfileStore(context, json)
    val queuedTurnStore = QueuedTurnStore(context, json)
    val composerDraftStore = ComposerDraftStore(context, json)
    val appearanceStore = AppearanceStore(context)
    val pinnedThreadStore = PinnedThreadStore(context)
    val sessionReminderStore = SessionReminderStore(context, json)
    val sessionReminderScheduler = SessionReminderScheduler(context)

    suspend fun prepareImage(uri: Uri) = ImageAttachmentEncoder.prepare(context.contentResolver, uri)
    val voiceRecorder = VoiceRecorder(context)
    val deviceSpeechTranscriber = DeviceSpeechTranscriber(context)
    val notificationCenter = NotificationCenter(context)

    suspend fun materializePreview(response: FileReadResponse): String = withContext(Dispatchers.IO) {
        val bytes = Base64.decode(response.contentBase64, Base64.DEFAULT)
        check(bytes.size.toLong() == response.size && bytes.size <= 20 * 1024 * 1024) { "File preview size is invalid" }
        val directory = File(context.cacheDir, "artifact-previews").apply { mkdirs() }
        val safeName = response.name.replace(Regex("[^A-Za-z0-9._-]"), "_").take(120).ifBlank { "preview.bin" }
        val target = File(directory, safeName)
        target.writeBytes(bytes)
        target.absolutePath
    }
    val networkMonitor = NetworkMonitor(context)
}
