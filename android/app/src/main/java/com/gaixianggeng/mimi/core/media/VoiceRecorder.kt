package com.gaixianggeng.mimi.core.media

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import java.io.Closeable
import java.io.File

class VoiceRecorder(private val context: Context) : Closeable {
    private var recorder: MediaRecorder? = null
    private var output: File? = null

    @Synchronized
    fun start() {
        check(recorder == null) { "Voice recording is already active" }
        val file = File(context.cacheDir, "voice-${System.currentTimeMillis()}.m4a")
        @Suppress("DEPRECATION")
        val next = (if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else MediaRecorder()).apply {
            setAudioSource(MediaRecorder.AudioSource.MIC)
            setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            setAudioSamplingRate(16_000)
            setAudioEncodingBitRate(64_000)
            setMaxDuration(120_000)
            setMaxFileSize(12L * 1024L * 1024L)
            setOutputFile(file.absolutePath)
            prepare()
            start()
        }
        output = file
        recorder = next
    }

    @Synchronized
    fun stop(): File {
        val active = recorder ?: error("Voice recording is not active")
        val file = requireNotNull(output)
        recorder = null
        output = null
        try {
            active.stop()
        } catch (failure: RuntimeException) {
            file.delete()
            throw IllegalStateException("Recording was too short; hold the microphone and speak for at least one second", failure)
        } finally {
            active.reset()
            active.release()
        }
        check(file.isFile && file.length() > 0) { "Voice recording is empty" }
        return file
    }

    @Synchronized
    fun cancel() {
        val active = recorder
        recorder = null
        try { active?.stop() } catch (_: RuntimeException) { }
        active?.reset()
        active?.release()
        output?.delete()
        output = null
    }

    override fun close() = cancel()
}
