package com.gaixianggeng.mimi.core.media

import android.Manifest
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class VoiceRecorderDeviceTest {
    @Test
    fun recorderProducesBoundedM4aOnDevice() {
        runBlocking {
            val context = ApplicationProvider.getApplicationContext<android.content.Context>()
            InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(
                context.packageName,
                Manifest.permission.RECORD_AUDIO,
            )
            val recorder = VoiceRecorder(context)
            recorder.start()
            delay(1_500)
            val file = recorder.stop()
            assertTrue(file.isFile)
            assertTrue(file.length() in 1 until 12L * 1024L * 1024L)
            file.delete()
        }
    }
}
