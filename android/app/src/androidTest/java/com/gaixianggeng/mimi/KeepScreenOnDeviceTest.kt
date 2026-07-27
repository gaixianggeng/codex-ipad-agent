package com.gaixianggeng.mimi

import android.os.SystemClock
import android.view.WindowManager
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.gaixianggeng.mimi.core.storage.AppearanceStore
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class KeepScreenOnDeviceTest {
    @Test
    fun preferenceControlsActivityWindowFlagAndRestoresOriginalValue() = runBlocking {
        val store = AppearanceStore(InstrumentationRegistry.getInstrumentation().targetContext)
        val original = store.preferences.first().keepScreenOn
        store.setKeepScreenOn(true)
        try {
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                assertTrue(waitForFlag(scenario, expected = true))
                store.setKeepScreenOn(false)
                assertTrue(waitForFlag(scenario, expected = false))
            }
        } finally {
            store.setKeepScreenOn(original)
        }
        assertEquals(original, store.preferences.first().keepScreenOn)
    }

    private fun waitForFlag(
        scenario: ActivityScenario<MainActivity>,
        expected: Boolean,
    ): Boolean {
        repeat(40) {
            var enabled = false
            scenario.onActivity { activity ->
                enabled = activity.window.attributes.flags and
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0
            }
            if (enabled == expected) return true
            SystemClock.sleep(50)
        }
        return false
    }
}
