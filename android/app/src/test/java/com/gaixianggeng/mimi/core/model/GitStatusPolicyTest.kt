package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class GitStatusPolicyTest {
    @Test
    fun statusMustBelongToRequestedRepositoryAndContainUniqueValidPaths() {
        val status = GitStatusResponse(
            path = "/other",
            isRepository = true,
            files = listOf(GitFileStatus("README.md", " M", unstaged = true)),
        )

        assertThrows(IllegalArgumentException::class.java) {
            GitStatusPolicy.sanitize(status, "/repo")
        }
        assertThrows(IllegalArgumentException::class.java) {
            GitStatusPolicy.sanitize(
                status.copy(
                    path = "/repo",
                    files = listOf(
                        GitFileStatus("README.md", " M"),
                        GitFileStatus("README.md", "M "),
                    ),
                ),
                "/repo",
            )
        }
    }

    @Test
    fun largeStatusIsBoundedAndMarkedTruncated() {
        val status = GitStatusResponse(
            path = "/repo",
            isRepository = true,
            branch = "b".repeat(GitStatusPolicy.MAX_BRANCH_CHARS + 1),
            unstagedDiff = "x".repeat(GitStatusPolicy.MAX_DIFF_CHARS + 1),
            files = List(GitStatusPolicy.MAX_FILES + 1) {
                GitFileStatus("file-$it", " M", unstaged = true)
            },
        )

        val sanitized = GitStatusPolicy.sanitize(status, "/repo")

        assertEquals(GitStatusPolicy.MAX_FILES, sanitized.files.size)
        assertEquals(GitStatusPolicy.MAX_DIFF_CHARS, sanitized.unstagedDiff?.length)
        assertEquals(GitStatusPolicy.MAX_BRANCH_CHARS, sanitized.branch?.length)
        assertTrue(sanitized.truncated == true)
    }
}
