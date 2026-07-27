package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionReminderPolicyTest {
    @Test
    fun routeAndScheduleAreBoundedAndProjectScoped() {
        val now = 1_000_000L
        val valid = SessionReminder(
            profileId = "profile",
            projectId = "project",
            threadId = "thread",
            title = "Review Android",
            fireAtEpochMillis = now + 60_000,
            createdAtEpochMillis = now,
        )

        assertTrue(SessionReminderPolicy.validate(valid, now) === valid)
        assertThrows(IllegalArgumentException::class.java) {
            SessionReminderPolicy.validate(valid.copy(projectId = " project "), now)
        }
        assertThrows(IllegalArgumentException::class.java) {
            SessionReminderPolicy.validate(
                valid.copy(fireAtEpochMillis = now + SessionReminderPolicy.MAX_DELAY_MILLIS + 1),
                now,
            )
        }
    }
}
