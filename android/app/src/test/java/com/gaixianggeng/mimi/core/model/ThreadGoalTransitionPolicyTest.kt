package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Test

class ThreadGoalTransitionPolicyTest {
    @Test
    fun activeCanPauseCompleteOrBlock() {
        assertEquals(
            listOf(ThreadGoalStatus.Paused, ThreadGoalStatus.Complete, ThreadGoalStatus.Blocked),
            ThreadGoalTransitionPolicy.allowedTransitions(ThreadGoalStatus.Active),
        )
    }

    @Test
    fun pausedBlockedAndLimitedGoalsCanResumeOrComplete() {
        val expected = listOf(ThreadGoalStatus.Active, ThreadGoalStatus.Complete)
        listOf(
            ThreadGoalStatus.Paused,
            ThreadGoalStatus.Blocked,
            ThreadGoalStatus.UsageLimited,
            ThreadGoalStatus.BudgetLimited,
        ).forEach { status ->
            assertEquals(expected, ThreadGoalTransitionPolicy.allowedTransitions(status))
        }
    }

    @Test
    fun completeGoalCanBeReactivated() {
        assertEquals(
            listOf(ThreadGoalStatus.Active),
            ThreadGoalTransitionPolicy.allowedTransitions(ThreadGoalStatus.Complete),
        )
    }
}
