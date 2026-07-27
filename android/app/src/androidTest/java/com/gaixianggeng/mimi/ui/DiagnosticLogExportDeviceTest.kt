package com.gaixianggeng.mimi.ui

import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class DiagnosticLogExportDeviceTest {
    @Test
    fun shareIntentContainsOnlyBoundedRedactedPlainText() {
        val intent = diagnosticLogShareIntent(
            subject = "Mimi Remote diagnostic log",
            logs = listOf(
                "2026-07-23T00:00:00Z event thread/started",
                "Authorization: Bearer DEVICE-SECRET",
                "prompt=PRIVATE PROMPT",
                "body=PRIVATE BODY",
            ),
        )

        assertEquals(Intent.ACTION_SEND, intent.action)
        assertEquals("text/plain", intent.type)
        assertEquals("Mimi Remote diagnostic log", intent.getStringExtra(Intent.EXTRA_SUBJECT))
        val text = intent.getStringExtra(Intent.EXTRA_TEXT).orEmpty()
        listOf("DEVICE-SECRET", "PRIVATE PROMPT", "PRIVATE BODY").forEach {
            assertFalse(text.contains(it))
        }
        assertNull(intent.data)
        assertNull(intent.component)
        assertNull(intent.`package`)
        assertNull(intent.clipData)
    }
}
