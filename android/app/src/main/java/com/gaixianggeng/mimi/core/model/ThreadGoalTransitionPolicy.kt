package com.gaixianggeng.mimi.core.model

/**
 * Keeps Android's goal lifecycle aligned with the Codex app-server contract and
 * the existing iOS client. Transitions are explicit so the UI never invents a
 * status that the user did not select.
 */
object ThreadGoalTransitionPolicy {
    fun canTransition(from: ThreadGoalStatus, to: ThreadGoalStatus): Boolean =
        to in allowedTransitions(from)

    fun allowedTransitions(status: ThreadGoalStatus): List<ThreadGoalStatus> = when (status) {
        ThreadGoalStatus.Active -> listOf(
            ThreadGoalStatus.Paused,
            ThreadGoalStatus.Complete,
            ThreadGoalStatus.Blocked,
        )
        ThreadGoalStatus.Paused,
        ThreadGoalStatus.Blocked,
        ThreadGoalStatus.UsageLimited,
        ThreadGoalStatus.BudgetLimited,
        -> listOf(ThreadGoalStatus.Active, ThreadGoalStatus.Complete)
        ThreadGoalStatus.Complete -> listOf(ThreadGoalStatus.Active)
    }
}
