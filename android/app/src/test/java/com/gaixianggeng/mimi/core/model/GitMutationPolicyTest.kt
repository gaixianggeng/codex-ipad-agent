package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class GitMutationPolicyTest {
    @Test
    fun untrackedFilesCannotBeDiscardedButMixedTrackedFilesExposeAllValidActions() {
        val untracked = GitMutationPolicy.availableFileActions(
            GitFileStatus(path = "new.txt", code = "??", untracked = true, unstaged = true),
        )
        val mixed = GitMutationPolicy.availableFileActions(
            GitFileStatus(path = "changed.txt", code = "MM", staged = true, unstaged = true),
        )

        assertEquals(setOf(GitActionKind.Stage), untracked)
        assertEquals(setOf(GitActionKind.Stage, GitActionKind.Unstage, GitActionKind.Revert), mixed)
    }

    @Test
    fun fileActionsRequireBoundedUniqueFilesAndMatchingActionKind() {
        val request = GitMutationPolicy.fileRequest(
            path = "/repo",
            action = GitActionKind.Stage,
            files = listOf("README.md", "app/src/Main.kt"),
        )

        assertEquals(listOf("README.md", "app/src/Main.kt"), request.files)
        assertNull(request.patch)
        assertThrows(IllegalArgumentException::class.java) {
            GitMutationPolicy.fileRequest("/repo", GitActionKind.StagePatch, listOf("README.md"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            GitMutationPolicy.fileRequest("/repo", GitActionKind.Stage, listOf("README.md", "README.md"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            GitMutationPolicy.fileRequest("/repo", GitActionKind.Stage, List(GitMutationPolicy.MAX_FILES + 1) { "file-$it" })
        }
    }

    @Test
    fun patchActionsRequireACompleteBoundedHunkAndMatchingActionKind() {
        val patch = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n"
        val request = GitMutationPolicy.patchRequest("/repo", GitActionKind.RevertPatch, patch)

        assertEquals(patch, request.patch)
        assertEquals(emptyList<String>(), request.files)
        assertThrows(IllegalArgumentException::class.java) {
            GitMutationPolicy.patchRequest("/repo", GitActionKind.Revert, patch)
        }
        assertThrows(IllegalArgumentException::class.java) {
            GitMutationPolicy.patchRequest("/repo", GitActionKind.StagePatch, "@@ -1 +1 @@\n-old\n+new")
        }
        assertThrows(IllegalArgumentException::class.java) {
            GitMutationPolicy.patchRequest(
                "/repo",
                GitActionKind.StagePatch,
                patch + "x".repeat(GitMutationPolicy.MAX_PATCH_CHARS),
            )
        }
    }
}
