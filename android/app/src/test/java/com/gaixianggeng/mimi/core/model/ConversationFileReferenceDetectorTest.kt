package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Test

class ConversationFileReferenceDetectorTest {
    @Test
    fun findsPreviewableAbsolutePathsAndRejectsWebUrls() {
        val references = ConversationFileReferenceDetector.references(
            """
            Generated:
            - `/tmp/report.pdf`
            - file:///tmp/chart.png?download=1
            - /tmp/report.pdf
            - /tmp/source.swift:12
            - https://example.com/file.pdf
            - /tmp/output
            """.trimIndent(),
        )

        assertEquals(listOf("/tmp/report.pdf", "/tmp/chart.png"), references.map { it.path })
        assertEquals(listOf("report.pdf", "chart.png"), references.map { it.name })
    }

    @Test
    fun imageReferencesKeepSpacesAndOnlyImageExtensions() {
        val references = ConversationFileReferenceDetector.imageReferences(
            """
            See /repo/screen.png and /repo/report.pdf, then file:///repo/nested/photo.webp.
            photo: /Users/me/Pictures/Photos%20Library/photo%20one.jpeg
            """.trimIndent(),
        )

        assertEquals(
            listOf("/repo/screen.png", "/repo/nested/photo.webp", "/Users/me/Pictures/Photos Library/photo one.jpeg"),
            references.map { it.path },
        )
    }

    @Test
    fun appliesLimitAndDeduplicates() {
        val text = "/tmp/a.txt /tmp/a.txt /tmp/b.json /tmp/c.pdf"
        assertEquals(listOf("/tmp/a.txt", "/tmp/b.json"), ConversationFileReferenceDetector.references(text, limit = 2).map { it.path })
        assertEquals(emptyList<ConversationFileReference>(), ConversationFileReferenceDetector.references(text, limit = 0))
    }
}
