package com.gaixianggeng.mimi.core.logging

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DiagnosticLogPolicyTest {
    @Test
    fun entriesContainOnlyBoundedNamesAndRedactAccidentalSensitiveValues() {
        val entry = DiagnosticLogPolicy.event(
            "thread/started\r\nAuthorization: Bearer TOP-SECRET prompt=private body=hidden token=abc",
            Instant.parse("2026-07-23T00:00:00Z"),
        )

        assertTrue(entry.startsWith("2026-07-23T00:00:00Z event "))
        listOf("TOP-SECRET", "private", "hidden", "abc").forEach {
            assertFalse(entry.contains(it))
        }
        assertTrue(entry.length <= 240)
        assertFalse(entry.contains('\n'))
        assertFalse(entry.contains('\r'))
    }

    @Test
    fun bufferAndExportKeepOnlyNewestFiveHundredEntries() {
        var entries = emptyList<String>()
        repeat(510) { index ->
            entries = DiagnosticLogPolicy.append(entries, "line-$index")
        }

        assertEquals(500, entries.size)
        assertEquals("line-10", entries.first())
        assertEquals("line-509", entries.last())
        assertEquals(500, DiagnosticLogPolicy.export(entries).lineSequence().count())
    }

    @Test
    fun exportRedactsUnexpectedLegacyLinesBeforeSharing() {
        val exported = DiagnosticLogPolicy.export(
            listOf(
                "Authorization=Bearer legacy-secret",
                "token=abc123",
                "prompt=do not export this",
                "body=private payload",
            ),
        )

        listOf("legacy-secret", "abc123", "do not export this", "private payload").forEach {
            assertFalse(exported.contains(it))
        }
        assertTrue(exported.contains("[redacted]"))
    }
}
