package com.gaixianggeng.mimi.core.media

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.speech.ModelDownloadListener
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.SpeechRecognizer
import androidx.annotation.RequiresApi
import java.io.Closeable
import java.util.Locale
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

class DeviceSpeechTranscriber(private val context: Context) : Closeable {
    private var active: SpeechRecognizer? = null

    fun isAvailable(): Boolean = android.os.Build.VERSION.SDK_INT >= 31 &&
        SpeechRecognizer.isOnDeviceRecognitionAvailable(context)

    suspend fun transcribe(): String = suspendCancellableCoroutine { continuation ->
        check(Build.VERSION.SDK_INT >= 31) { "On-device speech recognition requires Android 12 or newer" }
        check(isAvailable()) { "On-device speech recognition is not available for this device" }
        check(active == null) { "Speech recognition is already active" }
        val recognizer = if (Build.VERSION.SDK_INT >= 31) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } else {
            error("On-device speech recognition requires Android 12 or newer")
        }
        active = recognizer
        var downloadAttempted = false
        var activeIntent = recognitionIntent(currentLanguageTag())

        fun finish(result: Result<String>) {
            if (active !== recognizer) return
            active = null
            recognizer.destroy()
            if (!continuation.isActive) return
            result.onSuccess { continuation.resume(it) }
                .onFailure { continuation.resumeWithException(it) }
        }

        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) = Unit
            override fun onBeginningOfSpeech() = Unit
            override fun onRmsChanged(rmsdB: Float) = Unit
            override fun onBufferReceived(buffer: ByteArray?) = Unit
            override fun onEndOfSpeech() = Unit
            override fun onError(error: Int) {
                if (
                    error == SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE &&
                    Build.VERSION.SDK_INT >= 33 &&
                    !downloadAttempted
                ) {
                    downloadAttempted = true
                    requestModelDownload(
                        recognizer = recognizer,
                        intent = activeIntent,
                        onReady = { recognizer.startListening(activeIntent) },
                        onScheduled = {
                            finish(Result.failure(DeviceSpeechException(DeviceSpeechFailure.ModelDownloadScheduled)))
                        },
                        onFailure = {
                            finish(Result.failure(DeviceSpeechException(DeviceSpeechFailure.ModelUnavailable, it)))
                        },
                    )
                } else {
                    finish(Result.failure(errorFor(error)))
                }
            }
            override fun onResults(results: Bundle?) {
                val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.trim().orEmpty()
                finish(
                    if (text.isBlank()) {
                        Result.failure(DeviceSpeechException(DeviceSpeechFailure.NoMatch))
                    } else {
                        Result.success(text)
                    },
                )
            }
            override fun onPartialResults(partialResults: Bundle?) = Unit
            override fun onEvent(eventType: Int, params: Bundle?) = Unit
        })
        continuation.invokeOnCancellation {
            if (active === recognizer) active = null
            recognizer.cancel()
            recognizer.destroy()
        }
        if (Build.VERSION.SDK_INT < 33) {
            recognizer.startListening(activeIntent)
            return@suspendCancellableCoroutine
        }
        recognizer.checkRecognitionSupport(
            activeIntent,
            context.mainExecutor,
            object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) {
                    if (active !== recognizer || !continuation.isActive) return
                    val selection = DeviceSpeechSupportPolicy.select(
                        requestedLanguageTag = currentLanguageTag(),
                        installedLanguageTags = support.installedOnDeviceLanguages,
                        pendingLanguageTags = support.pendingOnDeviceLanguages,
                        supportedLanguageTags = support.supportedOnDeviceLanguages,
                    )
                    activeIntent = recognitionIntent(selection.languageTag)
                    when (selection.decision) {
                        DeviceSpeechSupportDecision.Ready -> recognizer.startListening(activeIntent)
                        DeviceSpeechSupportDecision.DownloadPending -> finish(
                            Result.failure(DeviceSpeechException(DeviceSpeechFailure.ModelDownloadScheduled)),
                        )
                        DeviceSpeechSupportDecision.DownloadRequired -> requestModelDownload(
                            recognizer = recognizer,
                            intent = activeIntent,
                            onReady = { recognizer.startListening(activeIntent) },
                            onScheduled = {
                                finish(Result.failure(DeviceSpeechException(DeviceSpeechFailure.ModelDownloadScheduled)))
                            },
                            onFailure = {
                                finish(Result.failure(DeviceSpeechException(DeviceSpeechFailure.ModelUnavailable, it)))
                            },
                        )
                        DeviceSpeechSupportDecision.Unsupported -> finish(
                            Result.failure(DeviceSpeechException(DeviceSpeechFailure.UnsupportedLanguage)),
                        )
                    }
                }

                override fun onError(error: Int) {
                    finish(Result.failure(DeviceSpeechException(DeviceSpeechFailure.ModelUnavailable, error)))
                }
            },
        )
    }

    fun cancel() {
        active?.cancel()
        active?.destroy()
        active = null
    }

    override fun close() = cancel()

    private fun recognitionIntent(languageTag: String = currentLanguageTag()) =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, languageTag)
        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
    }

    private fun currentLanguageTag(): String =
        context.resources.configuration.locales[0]?.toLanguageTag()
            ?.takeIf(String::isNotBlank)
            ?: Locale.getDefault().toLanguageTag()

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun requestModelDownload(
        recognizer: SpeechRecognizer,
        intent: Intent,
        onReady: () -> Unit,
        onScheduled: () -> Unit,
        onFailure: (Int) -> Unit,
    ) {
        if (Build.VERSION.SDK_INT < 34) {
            recognizer.triggerModelDownload(intent)
            onScheduled()
            return
        }
        recognizer.triggerModelDownload(
            intent,
            context.mainExecutor,
            object : ModelDownloadListener {
                override fun onSuccess() = onReady()
                override fun onScheduled() = onScheduled()
                override fun onProgress(completedPercent: Int) = Unit
                override fun onError(error: Int) = onFailure(error)
            },
        )
    }

    private fun errorFor(code: Int): DeviceSpeechException = when (code) {
        SpeechRecognizer.ERROR_AUDIO -> DeviceSpeechFailure.Audio
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> DeviceSpeechFailure.Permission
        SpeechRecognizer.ERROR_NETWORK,
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT,
        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> DeviceSpeechFailure.ModelUnavailable
        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> DeviceSpeechFailure.UnsupportedLanguage
        SpeechRecognizer.ERROR_NO_MATCH -> DeviceSpeechFailure.NoMatch
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> DeviceSpeechFailure.Busy
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> DeviceSpeechFailure.NoSpeech
        else -> DeviceSpeechFailure.Generic
    }.let { DeviceSpeechException(it, code) }
}
