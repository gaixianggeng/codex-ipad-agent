package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GitPatchParserTest {
    @Test
    fun `each hunk retains its complete file header`() {
        val diff = """diff --git a/app.kt b/app.kt
index 111..222 100644
--- a/app.kt
+++ b/app.kt
@@ -1 +1 @@
-old
+new
@@ -10 +10 @@
-before
+after
"""

        val hunks = GitPatchParser.parse(diff)

        assertEquals(2, hunks.size)
        assertTrue(hunks.all { it.patch.startsWith("diff --git a/app.kt b/app.kt\n") })
        assertTrue(hunks.first().title.startsWith("app.kt"))
        assertTrue(hunks.last().patch.contains("@@ -10 +10 @@"))
    }
}
