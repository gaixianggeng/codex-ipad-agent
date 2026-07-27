package com.gaixianggeng.mimi.ui

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.charset.StandardCharsets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FileProviderPreviewDeviceTest {
    @Test
    fun buildsAReadOnlyPdfViewContract() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val directory = File(context.cacheDir, "artifact-previews").apply { mkdirs() }
        val pdf = File(directory, "device-preview.pdf")

        try {
            pdf.writeBytes(minimalPdf())
            val viewIntent = artifactViewIntent(context, pdf.absolutePath, "application/pdf")
            val uri = requireNotNull(viewIntent.data)

            assertEquals("content", uri.scheme)
            assertEquals("application/pdf", context.contentResolver.getType(uri))
            assertEquals(Intent.ACTION_VIEW, viewIntent.action)
            assertEquals("application/pdf", viewIntent.type)
            assertEquals(uri, viewIntent.data)
            assertTrue(viewIntent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        } finally {
            pdf.delete()
        }
    }

    @Test
    fun launchesTheSystemPdfViewerSurface() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val directory = File(context.cacheDir, "artifact-previews").apply { mkdirs() }
        val pdf = File(directory, "system-viewer-test.pdf")

        try {
            pdf.writeBytes(minimalPdf())
            val chooser = Intent.createChooser(
                artifactViewIntent(context, pdf.absolutePath, "application/pdf"),
                "Mimi PDF viewer test",
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

            context.startActivity(chooser)
            SystemClock.sleep(1_000)
            instrumentation.waitForIdleSync()

            val activities = ParcelFileDescriptor.AutoCloseInputStream(
                instrumentation.uiAutomation.executeShellCommand("dumpsys activity activities"),
            ).bufferedReader().use { it.readText() }
            val resumedActivity = activities.lineSequence()
                .firstOrNull {
                    it.contains("mResumedActivity:") || it.contains("topResumedActivity=")
                }
                .orEmpty()
            assertTrue("No resumed activity found in:\n$activities", resumedActivity.isNotBlank())
            assertFalse(
                "PDF viewer did not leave Mimi: $resumedActivity",
                resumedActivity.contains(context.packageName),
            )
        } finally {
            instrumentation.uiAutomation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)
            SystemClock.sleep(300)
            pdf.delete()
        }
    }

    private fun minimalPdf(): ByteArray {
        val output = ByteArrayOutputStream()
        val offsets = mutableListOf<Int>()
        fun write(value: String) {
            output.write(value.toByteArray(StandardCharsets.ISO_8859_1))
        }
        fun objectBody(number: Int, body: String) {
            offsets += output.size()
            write("$number 0 obj\n$body\nendobj\n")
        }

        write("%PDF-1.4\n")
        objectBody(1, "<< /Type /Catalog /Pages 2 0 R >>")
        objectBody(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        objectBody(
            3,
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 360 180] " +
                "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        )
        val content = "BT /F1 20 Tf 36 90 Td (Mimi PDF Preview OK) Tj ET"
        objectBody(4, "<< /Length ${content.length} >>\nstream\n$content\nendstream")
        objectBody(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        val xrefOffset = output.size()
        write("xref\n0 6\n0000000000 65535 f \n")
        offsets.forEach { offset -> write("%010d 00000 n \n".format(offset)) }
        write("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n$xrefOffset\n%%EOF\n")
        return output.toByteArray()
    }
}
