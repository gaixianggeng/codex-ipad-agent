package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class GitPublishPolicyTest {
    @Test
    fun publishRequestsRequireExplicitConfirmationAndBoundedContent() {
        val quick = GitPublishPolicy.quickPublishRequest("/repo", "Ship Android", confirmed = true)
        val testFlight = GitPublishPolicy.testFlightRun("/repo", "Verify pairing", confirmed = true)
        val pullRequest = GitPublishPolicy.pullRequest("/repo", "Android parity", "Details", draft = true)

        assertTrue(quick.confirmed)
        assertTrue(testFlight.confirmed)
        assertTrue(pullRequest.draft)
        assertThrows(IllegalArgumentException::class.java) {
            GitPublishPolicy.quickPublishRequest("/repo", "Ship Android", confirmed = false)
        }
        assertThrows(IllegalArgumentException::class.java) {
            GitPublishPolicy.testFlightRun("/repo", "Verify pairing", confirmed = false)
        }
        assertThrows(IllegalArgumentException::class.java) {
            GitPublishPolicy.pullRequest("/repo", "x".repeat(257), "", draft = false)
        }
        assertThrows(IllegalArgumentException::class.java) {
            GitPublishPolicy.commitRequest("/repo", "x".repeat(501))
        }
    }

    @Test
    fun remoteOutputIsBoundedBeforeEnteringUiState() {
        val response = GitTestFlightStatusResponse(
            path = "/repo",
            capability = GitTestFlightCapability(
                isIosProject = true,
                available = true,
                reason = "ready",
            ),
            job = GitTestFlightJob(
                id = "job-1",
                state = "running",
                output = "x".repeat(GitPublishPolicy.MAX_OUTPUT_CHARS + 1),
                startedAt = "2026-07-24T00:00:00Z",
            ),
        )

        val bounded = GitPublishPolicy.bound(response)

        assertEquals(GitPublishPolicy.MAX_OUTPUT_CHARS, bounded.job?.output?.length)
        assertTrue(bounded.job?.truncated == true)
    }
}
