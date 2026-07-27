package com.gaixianggeng.mimi.core.model

enum class SessionLibraryFilter {
    All,
    Active,
    NeedsAttention,
    History,
}

enum class SessionRowStatus {
    WaitingForApproval,
    WaitingForInput,
    Running,
    Failed,
    Complete,
    Ended,
    Idle,
    History,
    Unknown,
}

object SessionLibraryPolicy {
    fun status(
        context: SessionContextStatus?,
        hasActiveTurn: Boolean = false,
        hasPendingApproval: Boolean = false,
        hasPendingUserInput: Boolean = false,
    ): SessionRowStatus {
        val flags = context?.activeFlags.orEmpty()
            .map { it.normalizedStatus() }
            .toSet()
        if (hasPendingApproval || "waitingonapproval" in flags) {
            return SessionRowStatus.WaitingForApproval
        }
        if (hasPendingUserInput || "waitingonuserinput" in flags || "waitingforinput" in flags) {
            return SessionRowStatus.WaitingForInput
        }
        if (hasActiveTurn) return SessionRowStatus.Running

        return when ((context?.rawType ?: context?.type).orEmpty().normalizedStatus()) {
            "waitingforapproval", "waitingonapproval" -> SessionRowStatus.WaitingForApproval
            "waitingforinput", "waitingonuserinput" -> SessionRowStatus.WaitingForInput
            "active", "running", "started", "inprogress" -> SessionRowStatus.Running
            "failed", "failure", "error", "systemerror" -> SessionRowStatus.Failed
            "completed", "complete", "success", "succeeded" -> SessionRowStatus.Complete
            "closed", "ended" -> SessionRowStatus.Ended
            "idle" -> SessionRowStatus.Idle
            "history", "notloaded" -> SessionRowStatus.History
            else -> SessionRowStatus.Unknown
        }
    }

    fun isActive(status: SessionRowStatus): Boolean = status in setOf(
        SessionRowStatus.WaitingForApproval,
        SessionRowStatus.WaitingForInput,
        SessionRowStatus.Running,
    )

    fun needsAttention(status: SessionRowStatus): Boolean = status in setOf(
        SessionRowStatus.WaitingForApproval,
        SessionRowStatus.WaitingForInput,
        SessionRowStatus.Failed,
    )

    fun includes(filter: SessionLibraryFilter, status: SessionRowStatus): Boolean = when (filter) {
        SessionLibraryFilter.All -> true
        SessionLibraryFilter.Active -> isActive(status)
        SessionLibraryFilter.NeedsAttention -> needsAttention(status)
        SessionLibraryFilter.History -> !isActive(status)
    }

    private fun String.normalizedStatus(): String =
        lowercase().replace("_", "").replace("-", "").replace(" ", "")
}
